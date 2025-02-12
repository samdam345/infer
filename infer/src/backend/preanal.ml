(*
 * Copyright (c) 2009-2013, Monoidics ltd.
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging

(** add Abstract instructions into the IR to give hints about when abstraction should be
    performed *)
module AddAbstractionInstructions = struct
  let process pdesc =
    let open Procdesc in
    (* true if there is a succ node s.t.: it is an exit node, or the succ of >1 nodes *)
    let converging_node node =
      let is_exit node = match Node.get_kind node with Node.Exit_node -> true | _ -> false in
      let succ_nodes = Node.get_succs node in
      if List.exists ~f:is_exit succ_nodes then true
      else
        match succ_nodes with [] -> false | [h] -> List.length (Node.get_preds h) > 1 | _ -> false
    in
    let node_requires_abstraction node =
      match Node.get_kind node with
      | Node.Start_node | Node.Join_node ->
          false
      | Node.Exit_node | Node.Stmt_node _ | Node.Prune_node _ | Node.Skip_node _ ->
          converging_node node
    in
    let do_node node =
      let loc = Node.get_last_loc node in
      if node_requires_abstraction node then Node.append_instrs node [Sil.Metadata (Abstract loc)]
    in
    Procdesc.iter_nodes do_node pdesc
end

(** perform liveness analysis and insert Nullify/Remove_temps instructions into the IR to make it
    easy for analyses to do abstract garbage collection *)
module Liveness = struct
  module BackwardCfg = ProcCfg.Backward (ProcCfg.Exceptional)
  module LivenessAnalysis =
    AbstractInterpreter.MakeRPO (Liveness.PreAnalysisTransferFunctions (BackwardCfg))
  module VarDomain = Liveness.Domain

  (** computes the non-nullified reaching definitions at the end of each node by building on the
    results of a liveness analysis to be precise, what we want to compute is:

    to_nullify := (live_before U non_nullifed_reaching_defs) - live_after

    non_nullified_reaching_defs := non_nullified_reaching_defs - to_nullify

    Note that this can't be done with by combining the results of reaching definitions and liveness
    after the fact, nor can it be done with liveness alone. We will insert nullify instructions for
    each pvar in to_nullify afer we finish the analysis. Nullify instructions speed up the analysis
    by enabling it to GC state that will no longer be read. *)
  module NullifyTransferFunctions = struct
    module Domain = AbstractDomain.Pair (VarDomain) (VarDomain)
    (** (reaching non-nullified vars) * (vars to nullify) *)

    module CFG = ProcCfg.Exceptional

    type extras = LivenessAnalysis.invariant_map

    let postprocess ((reaching_defs, _) as astate) node {ProcData.extras} =
      let node_id = Procdesc.Node.get_id (CFG.Node.underlying_node node) in
      match LivenessAnalysis.extract_state node_id extras with
      (* note: because the analysis is backward, post and pre are reversed *)
      | Some {AbstractInterpreter.State.post= live_before; pre= live_after} ->
          let to_nullify = VarDomain.diff (VarDomain.union live_before reaching_defs) live_after in
          let reaching_defs' = VarDomain.diff reaching_defs to_nullify in
          (reaching_defs', to_nullify)
      | None ->
          astate


    let cache_node = ref (Procdesc.Node.dummy Typ.Procname.Linters_dummy_method)

    let cache_instr = ref Sil.skip_instr

    let last_instr_in_node node =
      let get_last_instr () =
        CFG.instrs node |> Instrs.last |> Option.value ~default:Sil.skip_instr
      in
      if phys_equal node !cache_node then !cache_instr
      else
        let last_instr = get_last_instr () in
        cache_node := node ;
        cache_instr := last_instr ;
        last_instr


    let is_last_instr_in_node instr node = phys_equal (last_instr_in_node node) instr

    let exec_instr ((active_defs, to_nullify) as astate) extras node instr =
      let astate' =
        match instr with
        | Sil.Load {id= lhs_id} ->
            (VarDomain.add (Var.of_id lhs_id) active_defs, to_nullify)
        | Sil.Call ((id, _), _, actuals, _, {CallFlags.cf_assign_last_arg}) ->
            let active_defs = VarDomain.add (Var.of_id id) active_defs in
            let active_defs =
              if cf_assign_last_arg then
                match IList.split_last_rev actuals with
                | Some ((Exp.Lvar pvar, _), _) ->
                    VarDomain.add (Var.of_pvar pvar) active_defs
                | _ ->
                    active_defs
              else active_defs
            in
            (active_defs, to_nullify)
        | Sil.Store {e1= Exp.Lvar lhs_pvar} ->
            (VarDomain.add (Var.of_pvar lhs_pvar) active_defs, to_nullify)
        | Sil.Metadata (VariableLifetimeBegins (pvar, _, _)) ->
            (VarDomain.add (Var.of_pvar pvar) active_defs, to_nullify)
        | Sil.Store _ | Prune _ | Metadata (Abstract _ | ExitScope _ | Skip) ->
            astate
        | Sil.Metadata (Nullify _) ->
            L.(die InternalError)
              "Should not add nullify instructions before running nullify analysis!"
      in
      if is_last_instr_in_node instr node then postprocess astate' node extras else astate'


    let pp_session_name _node fmt = Format.pp_print_string fmt "nullify"
  end

  module NullifyAnalysis = AbstractInterpreter.MakeRPO (NullifyTransferFunctions)

  let add_nullify_instrs summary tenv liveness_inv_map =
    let address_taken_vars =
      if Typ.Procname.is_java (Summary.get_proc_name summary) then AddressTaken.Domain.empty
        (* can't take the address of a variable in Java *)
      else
        let initial = AddressTaken.Domain.empty in
        match AddressTaken.Analyzer.compute_post (ProcData.make_default summary tenv) ~initial with
        | Some post ->
            post
        | None ->
            AddressTaken.Domain.empty
    in
    let nullify_proc_cfg = ProcCfg.Exceptional.from_pdesc (Summary.get_proc_desc summary) in
    let nullify_proc_data = ProcData.make summary tenv liveness_inv_map in
    let initial = (VarDomain.empty, VarDomain.empty) in
    let nullify_inv_map = NullifyAnalysis.exec_cfg nullify_proc_cfg nullify_proc_data ~initial in
    (* only nullify pvars that are local; don't nullify those that can escape *)
    let is_local pvar = not (Pvar.is_return pvar || Pvar.is_global pvar) in
    let prepend_node_nullify_instructions loc pvars instrs =
      List.fold pvars ~init:instrs ~f:(fun instrs pvar ->
          if is_local pvar then Sil.Metadata (Nullify (pvar, loc)) :: instrs else instrs )
    in
    let node_deadvars_instruction loc vars =
      let local_vars =
        List.rev_filter vars ~f:(function
          | Var.ProgramVar pvar ->
              is_local pvar
          | Var.LogicalVar _ ->
              true )
      in
      if List.is_empty local_vars then None else Some (Sil.Metadata (ExitScope (local_vars, loc)))
    in
    Container.iter nullify_proc_cfg ~fold:ProcCfg.Exceptional.fold_nodes ~f:(fun node ->
        match NullifyAnalysis.extract_post (ProcCfg.Exceptional.Node.id node) nullify_inv_map with
        | Some (_, to_nullify) ->
            let dead_vars, pvars_to_nullify =
              VarDomain.fold
                (fun var (dead_vars, pvars_to_nullify) ->
                  let pvars_to_nullify =
                    match Var.get_pvar var with
                    | Some pvar when not (AddressTaken.Domain.mem pvar address_taken_vars) ->
                        (* We nullify all address taken variables at the end of the procedure. This is
                           to avoid setting heap values to 0 that may be aliased somewhere else. *)
                        pvar :: pvars_to_nullify
                    | _ ->
                        pvars_to_nullify
                  in
                  (var :: dead_vars, pvars_to_nullify) )
                to_nullify ([], [])
            in
            let loc = Procdesc.Node.get_last_loc node in
            Option.to_list (node_deadvars_instruction loc dead_vars)
            |> prepend_node_nullify_instructions loc pvars_to_nullify
            |> Procdesc.Node.append_instrs node
        | None ->
            () ) ;
    (* nullify all address taken variables at the end of the procedure *)
    if not (AddressTaken.Domain.is_empty address_taken_vars) then
      let exit_node = ProcCfg.Exceptional.exit_node nullify_proc_cfg in
      let exit_loc = Procdesc.Node.get_last_loc exit_node in
      prepend_node_nullify_instructions exit_loc
        (AddressTaken.Domain.elements address_taken_vars)
        []
      |> Procdesc.Node.append_instrs exit_node


  let process summary tenv =
    let liveness_proc_cfg = BackwardCfg.from_pdesc (Summary.get_proc_desc summary) in
    let initial = Liveness.Domain.empty in
    let liveness_inv_map =
      LivenessAnalysis.exec_cfg liveness_proc_cfg (ProcData.make_default summary tenv) ~initial
    in
    add_nullify_instrs summary tenv liveness_inv_map
end

module FunctionPointerSubstitution = struct
  let process summary tenv =
    let updated = FunctionPointers.substitute_function_pointers summary tenv in
    let pdesc = Summary.get_proc_desc summary in
    if updated then Attributes.store ~proc_desc:(Some pdesc) (Procdesc.get_attributes pdesc)
end

(** pre-analysis to cut control flow after calls to functions whose type indicates they do not
    return *)
module NoReturn = struct
  let has_noreturn_call node =
    Procdesc.Node.get_instrs node
    |> Instrs.exists ~f:(fun (instr : Sil.instr) ->
           match instr with
           | Call (_, Const (Cfun proc_name), _, _, _) -> (
             match Attributes.load proc_name with
             | Some {ProcAttributes.is_no_return= true} ->
                 true
             | _ ->
                 false )
           | _ ->
               false )


  let process proc_desc =
    Procdesc.iter_nodes
      (fun node ->
        if has_noreturn_call node then Procdesc.set_succs node ~normal:(Some []) ~exn:None )
      proc_desc
end

let do_preanalysis exe_env pdesc =
  let summary = Summary.OnDisk.reset pdesc in
  let tenv = Exe_env.get_tenv exe_env (Procdesc.get_proc_name pdesc) in
  if
    Config.function_pointer_specialization
    && not (Typ.Procname.is_java (Procdesc.get_proc_name pdesc))
  then FunctionPointerSubstitution.process summary tenv ;
  Liveness.process summary tenv ;
  AddAbstractionInstructions.process pdesc ;
  NoReturn.process pdesc ;
  ()

(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format

module Bound : sig
  type t

  type eval_sym = t Symb.Symbol.eval

  val compare : t -> t -> int

  val equal : t -> t -> bool

  val pp_mark : markup:bool -> F.formatter -> t -> unit

  val of_int : int -> t

  val of_big_int : Z.t -> t

  val minf : t

  val mone : t

  val zero : t

  val one : t

  val z255 : t

  val pinf : t

  val of_normal_path :
    Symb.Symbol.make_t -> unsigned:bool -> ?non_int:bool -> Symb.SymbolPath.partial -> t

  val of_offset_path : is_void:bool -> Symb.Symbol.make_t -> Symb.SymbolPath.partial -> t

  val of_length_path : is_void:bool -> Symb.Symbol.make_t -> Symb.SymbolPath.partial -> t

  val of_modeled_path : Symb.Symbol.make_t -> Symb.SymbolPath.partial -> t

  val of_minmax_bound_min : t -> t -> t

  val of_minmax_bound_max : t -> t -> t

  val is_offset_path_of : Symb.SymbolPath.partial -> t -> bool

  val is_length_path_of : Symb.SymbolPath.partial -> t -> bool

  val is_zero : t -> bool

  val is_infty : t -> bool

  val is_not_infty : t -> bool

  val is_minf : t -> bool

  val is_pinf : t -> bool

  val is_symbolic : t -> bool

  val le : t -> t -> bool

  val lt : t -> t -> bool

  val gt : t -> t -> bool

  val eq : t -> t -> bool

  val xcompare : t PartialOrder.xcompare

  val underapprox_min : t -> t -> t

  val overapprox_min : t -> t -> t

  val underapprox_max : t -> t -> t

  val overapprox_max : t -> t -> t

  val widen_l : t -> t -> t

  val widen_l_thresholds : thresholds:Z.t list -> t -> t -> t

  val widen_u : t -> t -> t

  val widen_u_thresholds : thresholds:Z.t list -> t -> t -> t

  val get_const : t -> Z.t option

  val plus_l : weak:bool -> t -> t -> t

  val plus_u : weak:bool -> t -> t -> t

  val mult_const_l : Ints.NonZeroInt.t -> t -> t

  val mult_const_u : Ints.NonZeroInt.t -> t -> t

  val neg : t -> t

  val div_const_l : t -> Ints.NonZeroInt.t -> t option

  val div_const_u : t -> Ints.NonZeroInt.t -> t option

  val get_symbols : t -> Symb.SymbolSet.t

  val has_void_ptr_symb : t -> bool

  val are_similar : t -> t -> bool

  val subst_lb : t -> eval_sym -> t AbstractDomain.Types.bottom_lifted

  val subst_ub : t -> eval_sym -> t AbstractDomain.Types.bottom_lifted

  val simplify_bound_ends_from_paths : t -> t

  val simplify_min_one : t -> t

  val get_same_one_symbol : t -> t -> Symb.SymbolPath.t option

  val exists_str : f:(string -> bool) -> t -> bool
end

module BoundTrace : sig
  include PrettyPrintable.PrintableOrderedType

  val length : t -> int

  val make_err_trace : depth:int -> t -> Errlog.loc_trace

  val of_loop : Location.t -> t
end

type ('c, 's, 't) valclass = Constant of 'c | Symbolic of 's | ValTop of 't

module NonNegativeBound : sig
  type t [@@deriving compare]

  val leq : lhs:t -> rhs:t -> bool

  val join : t -> t -> t

  val widen : prev:t -> next:t -> num_iters:int -> t

  val of_loop_bound : Location.t -> Bound.t -> t

  val of_modeled_function : string -> Location.t -> Bound.t -> t

  val of_big_int : trace:BoundTrace.t -> Z.t -> t

  val pp : hum:bool -> Format.formatter -> t -> unit

  val make_err_trace : t -> string * Errlog.loc_trace

  val mask_min_max_constant : t -> t

  val zero : Location.t -> t

  val int_lb : t -> Ints.NonNegativeInt.t

  val int_ub : t -> Ints.NonNegativeInt.t option

  val classify : t -> (Ints.NonNegativeInt.t, t, BoundTrace.t) valclass

  val subst :
       Typ.Procname.t
    -> Location.t
    -> t
    -> Bound.eval_sym
    -> (Ints.NonNegativeInt.t, t, BoundTrace.t) valclass
end

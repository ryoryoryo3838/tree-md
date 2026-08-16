(** Minting an address for a tree that does not state one.

    The scheme follows the convention Forester documents for its own forests:
    a base-36 number, zero-padded to four digits. The point of a number is
    that it says nothing, so nobody is tempted to rename the tree when its
    title changes. *)

val encode : Config.id_policy -> int -> string
(** [encode policy n] renders [n] in the policy's alphabet, zero-padded to its
    width and widened when [n] needs more room, behind its prefix. *)

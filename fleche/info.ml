(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2018       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

(************************************************************************)
(* Coq Language Server Protocol                                         *)
(* Copyright (C) 2019 MINES ParisTech -- Dual License LGPL 2.1 / GPL3+  *)
(* Copyright (C) 2019-2022 Emilio J. Gallego Arias, INRIA               *)
(* Copyright (C) 2022-2022 Shachar Itzhaky, Technion                    *)
(************************************************************************)

module type Point = sig
  type t

  val in_range : ?loc:Loc.t -> t -> bool
  val gt_range : ?loc:Loc.t -> t -> bool

  type offset_table = string

  val to_offset : t -> offset_table -> int
  val to_string : t -> string
end

module LineCol : Point with type t = int * int = struct
  type t = int * int
  type offset_table = string

  let line_length offset text =
    match String.index_from_opt text offset '\n' with
    | Some l -> l - offset
    | None -> String.length text - offset

  let rec to_offset cur lc (l, c) text =
    Io.Log.error "to_offset"
      (Format.asprintf "cur: %d | lc: %d | l: %d c: %d" cur lc l c);
    if lc = l then cur + c
    else
      let ll = line_length cur text + 1 in
      to_offset (cur + ll) (lc + 1) (l, c) text

  let to_offset (l, c) text = to_offset 0 0 (l, c) text
  let to_string (l, c) = "(" ^ string_of_int l ^ "," ^ string_of_int c ^ ")"
  let debug_in_range = false

  let in_range ?loc (line, col) =
    (* Coq starts at 1, lsp at 0 *)
    match loc with
    | None -> false
    | Some loc ->
      let r = Types.to_range loc in
      let line1 = r.start.line in
      let col1 = r.start.character in
      let line2 = r._end.line in
      let col2 = r._end.character in
      if debug_in_range then
        Io.Log.error "in_range"
          (Format.asprintf "(%d, %d) in (%d,%d)-(%d,%d)" line col line1 col1
             line2 col2);
      (line1 < line && line < line2)
      ||
      if line1 = line && line2 = line then col1 <= col && col < col2
      else (line1 = line && col1 <= col) || (line2 = line && col < col2)

  let gt_range ?loc (line, col) =
    match loc with
    | None -> false
    | Some loc ->
      let r = Types.to_range loc in
      let line1 = r.start.line in
      let col1 = r.start.character in
      let line2 = r._end.line in
      let col2 = r._end.character in
      if debug_in_range then
        Io.Log.error "gt_range"
          (Format.asprintf "(%d, %d) in (%d,%d)-(%d,%d)" line col line1 col1
             line2 col2);
      line < line1 || (line = line1 && col < col1)
end

module Offset : Point with type t = int = struct
  type t = int
  type offset_table = string

  let in_range ?loc point =
    match loc with
    | None -> false
    | Some loc -> loc.Loc.bp <= point && point < loc.ep

  let gt_range ?loc point =
    match loc with
    | None -> false
    | Some loc -> point < loc.Loc.bp

  let to_offset off _ = off
  let to_string off = string_of_int off
end

type approx =
  | Exact
  (* Exact on point *)
  | PrevIfEmpty
  (* If no match, return prev *)
  | Prev

module type S = sig
  module P : Point

  type ('a, 'r) query = doc:Doc.t -> point:P.t -> 'a -> 'r option

  val goals : (approx, Coq.Goals.reified_pp) query
  val info : (approx, string) query
  val completion : (string, string list) query
end

let some x = Some x
let obind x f = Option.bind f x

module Make (P : Point) : S with module P := P = struct
  type ('a, 'r) query = doc:Doc.t -> point:P.t -> 'a -> 'r option

  let find ~doc ~point approx =
    let rec find prev l =
      match l with
      | [] -> prev
      | node :: xs -> (
        let loc = Coq.Ast.loc node.Doc.ast in
        match approx with
        | Exact -> if P.in_range ?loc point then Some node else find None xs
        | PrevIfEmpty ->
          if P.gt_range ?loc point then prev else find (Some node) xs
        | Prev ->
          if P.gt_range ?loc point || P.in_range ?loc point then prev
          else find (Some node) xs)
    in
    find None doc.Doc.nodes

  let if_not_empty (pp : Pp.t) =
    if Pp.(repr pp = Ppcmd_empty) then None else Some pp

  let reify_goals ppx lemmas =
    let open Coq.Goals in
    let proof =
      Vernacstate.LemmaStack.with_top lemmas ~f:(fun pstate ->
          Declare.Proof.get pstate)
    in
    let { Proof.goals; stack; sigma; _ } = Proof.data proof in
    let ppx = List.map (Coq.Goals.process_goal_gen ppx sigma) in
    Some
      { goals = ppx goals
      ; stack = List.map (fun (g1, g2) -> (ppx g1, ppx g2)) stack
      ; bullet = if_not_empty @@ Proof_bullet.suggest proof
      ; shelf = Evd.shelf sigma |> ppx
      ; given_up = Evd.given_up sigma |> Evar.Set.elements |> ppx
      }

  let pr_goal st =
    let ppx env sigma x =
      (* It is conveneint to optimize the Pp.t type, see [Jscoq_util.pp_opt] *)
      Printer.pr_ltype_env ~goal_concl_style:true env sigma x
    in
    let lemmas = Coq.State.lemmas ~st in
    Option.cata (reify_goals ppx) None lemmas

  let goals ~doc ~point approx =
    find ~doc ~point approx
    |> obind (fun node ->
           Coq.State.in_state ~st:node.Doc.state ~f:pr_goal node.Doc.state)

  let info ~doc ~point approx =
    find ~doc ~point approx |> Option.map (fun node -> node.Doc.memo_info)

  (* XXX: This belongs in Coq *)
  let pr_extref gr =
    match gr with
    | Globnames.TrueGlobal gr -> Printer.pr_global gr
    | Globnames.Abbrev kn -> Names.KerName.print kn

  (* XXX This may fail when passed "foo." for example, so more sanitizing is
     needed *)
  let to_qualid p = try Some (Libnames.qualid_of_string p) with _ -> None

  let completion ~doc ~point prefix =
    find ~doc ~point Exact
    |> obind (fun node ->
           Coq.State.in_state ~st:node.Doc.state prefix ~f:(fun prefix ->
               to_qualid prefix
               |> obind (fun p ->
                      Nametab.completion_canditates p
                      |> List.map (fun x -> Pp.string_of_ppcmds (pr_extref x))
                      |> some)))
end

module LC = Make (LineCol)
module O = Make (Offset)
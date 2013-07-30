(**************************************************************************)
(*                        Lem                                             *)
(*                                                                        *)
(*          Dominic Mulligan, University of Cambridge                     *)
(*          Francesco Zappa Nardelli, INRIA Paris-Rocquencourt            *)
(*          Gabriel Kerneis, University of Cambridge                      *)
(*          Kathy Gray, University of Cambridge                           *)
(*          Peter Boehm, University of Cambridge (while working on Lem)   *)
(*          Peter Sewell, University of Cambridge                         *)
(*          Scott Owens, University of Kent                               *)
(*          Thomas Tuerk, University of Cambridge                         *)
(*                                                                        *)
(*  The Lem sources are copyright 2010-2013                               *)
(*  by the UK authors above and Institut National de Recherche en         *)
(*  Informatique et en Automatique (INRIA).                               *)
(*                                                                        *)
(*  All files except ocaml-lib/pmap.{ml,mli} and ocaml-libpset.{ml,mli}   *)
(*  are distributed under the license below.  The former are distributed  *)
(*  under the LGPLv2, as in the LICENSE file.                             *)
(*                                                                        *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*  notice, this list of conditions and the following disclaimer.         *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*  notice, this list of conditions and the following disclaimer in the   *)
(*  documentation and/or other materials provided with the distribution.  *)
(*  3. The names of the authors may not be used to endorse or promote     *)
(*  products derived from this software without specific prior written    *)
(*  permission.                                                           *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS    *)
(*  OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED     *)
(*  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE    *)
(*  ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY       *)
(*  DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL    *)

(*  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE     *)
(*  GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS         *)
(*  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER  *)
(*  IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR       *)
(*  OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN   *)
(*  IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.                         *)
(**************************************************************************)

open Format
open Types
open Typed_ast
open Typed_ast_syntax
open Target
open Typecheck_ctxt

let r = Ulib.Text.of_latin1

module Refl = struct
  type t = const_descr_ref * Ast.l
  let compare (r1,_) (r2,_) =
    Pervasives.compare r1 r2
end

module ReflSet = Set.Make(Refl)

module DupRefs = Util.Duplicate(ReflSet)
module DupTvs = Util.Duplicate(TNset)

type pat_env = (Types.t * Ast.l) Nfmap.t
let empty_pat_env = Nfmap.empty

(* Non-top level binders map to a type, not a type scheme, method or constructor
 * *) 
type lex_env = (Types.t * Ast.l) Nfmap.t
let empty_lex_env = Nfmap.empty

let annot_name n l env = 
  { term = n;
    locn = l;
    typ = 
      begin
        match Nfmap.apply env (Name.strip_lskip n) with
          | Some((x,l)) -> x 
          | None -> assert false
      end;
    rest = (); }

let xl_to_nl xl = (Name.from_x xl, Ast.xl_to_l xl)

let id_to_identl id =
  (Ident.from_id id, match id with | Ast.Id(mp,xl,l) -> l)

(* Assume that the names in mp must refer to modules.  Corresponds to judgment
 * look_m 'E1(x1..xn) gives E2' *)
let rec path_lookup l (e : local_env) (mp : (Name.lskips_t * Ast.l) list) : local_env =   
  let mp_names = List.map (fun (n, _) -> Name.strip_lskip n) mp in
  match lookup_env_opt e mp_names with
    | Some e -> e
    | None -> 
      let mp_rev = List.rev mp_names in
      let p = Path.mk_path (List.rev (List.tl mp_rev)) (List.hd mp_rev) in
      raise (Reporting_basic.err_type_pp l "unknown module" Path.pp p)

(* Assume that the names in mp must refer to modules. Corresponds to judgment
 * look_m_id 'E1(id) gives E2' *)
let lookup_mod (e : local_env) (Ast.Id(mp,xl,l'')) : mod_descr = 
  let mp' = List.map (fun (xl,_) -> Name.strip_lskip (Name.from_x xl)) mp in
  let n = Name.strip_lskip (Name.from_x xl) in 
  match lookup_mod_descr_opt e mp' n with
      | None -> 
          raise (Reporting_basic.err_type_pp (Ast.xl_to_l xl) "unknown module"
            Name.pp (Name.strip_lskip (Name.from_x xl)))
      | Some(e) -> e

(* Assume that the names in mp must refer to modules. Corresponds to judgment
 * look_tc 'E(id) gives p' *)
let lookup_p msg (e : local_env) (Ast.Id(mp,xl,l) as i) : Path.t =
  let e = path_lookup l e (List.map (fun (xl,_) -> xl_to_nl xl) mp) in
    match Nfmap.apply e.p_env (Name.strip_lskip (Name.from_x xl)) with
      | None ->
          raise (Reporting_basic.err_type_pp l (Printf.sprintf "unbound type %s" msg)
            Ident.pp (Ident.from_id i))
      | Some(p, _) -> p

(* Assume that the names in mp must refer to modules. Looks up a name, not
   knowing what this name refers to. *)
let lookup_name (e : env) (Ast.Id(mp,xl,l) as i) : (name_kind * Path.t) =
  let e_l = path_lookup l e.local_env (List.map (fun (xl,_) -> xl_to_nl xl) mp) in
  let e = {e with local_env = e_l} in
    match env_apply e (Name.strip_lskip (Name.from_x xl)) with
      | None ->
          raise (Reporting_basic.err_type_pp l (Printf.sprintf "unbound name")
            Ident.pp (Ident.from_id i))
      | Some(nk, p, _) -> (nk, p)


(* Lookup in the lex env.  A formula in the formal type system *)
let lookup_l (l_e : lex_env) mp n : (t * Ast.l * Name.lskips_t) option =
  match mp with
    | [] -> 
        begin
          match Nfmap.apply l_e (Name.strip_lskip n) with
            | None -> None
            | Some((t,l)) -> Some((t,l,n))
        end
    | _ -> None

(* Checks the well-formedness of a type that appears in the source.  Corresponds
 * to judgment convert_typ 'Delta, E |- typ ~> t'.  The wild_f function is used
 * for an underscore/wildcard type (which should be allowed in type annotations,
 * but not in type definitions).  The do_tvar function is called on each type
 * variable in the type, for its side effect (e.g., to record the tvars that
 * occur in the type. *)

let rec nexp_to_src_nexp (do_nvar : Nvar.t -> unit) (Ast.Length_l(nexp,l)) : src_nexp =
  match nexp with
   | Ast.Nexp_var((sk,nv)) ->
     do_nvar(Nvar.from_rope nv);
     { nterm = Nexp_var(sk,Nvar.from_rope(nv)); 
       nloc =l; 
       nt = {nexp=Nvar(Nvar.from_rope(nv)); };}
   | Ast.Nexp_constant(sk,i) ->
     { nterm = Nexp_const(sk,i); 
       nloc=l; 
       nt = {nexp=Nconst(i);};}
   | Ast.Nexp_times(n1,sk,n2) ->
     let n1' = nexp_to_src_nexp do_nvar n1 in
     let n2' = nexp_to_src_nexp do_nvar n2 in
     { nterm = Nexp_mult(n1',sk,n2'); 
       nloc =l; 
       nt = {nexp=Nmult(n1'.nt,n2'.nt);};}
   | Ast.Nexp_sum(n1,sk,n2) ->
     let n1' = nexp_to_src_nexp do_nvar n1 in
     let n2' = nexp_to_src_nexp do_nvar n2 in
     { nterm = Nexp_add(n1',sk,n2');
       nloc =l;
       nt = {nexp=Nadd(n1'.nt,n2'.nt);}; }
   | Ast.Nexp_paren(sk1,n,sk2) ->
     let n' = nexp_to_src_nexp do_nvar n in
     { nterm = Nexp_paren(sk1,n',sk2);
       nloc = l;
       nt = n'.nt }

let tnvar_app_check l i tnv (t: src_t) : unit =
  match tnv, t.typ with
   | Nv _ , {t = Tne _} -> ()
   | Ty _ , {t = Tne _} -> 
     raise (Reporting_basic.err_type_pp l (Printf.sprintf "type constructor expected type argument, given a length")
         Ident.pp (Ident.from_id i))
     (* TODO KG: Improve this type error location and add variable name *)
   | Nv _ , _ -> 
     raise (Reporting_basic.err_type_pp l (Printf.sprintf "type constructor expected length argument, given a type")
         Ident.pp (Ident.from_id i))
   | Ty _ , _ -> ()

let rec typ_to_src_t (wild_f : Ast.l -> lskips -> src_t) 
      (do_tvar : Tyvar.t -> unit) (do_nvar : Nvar.t -> unit) (d : type_defs) (e : local_env) (Ast.Typ_l(typ,l)) 
      : src_t = 
  match typ with
    | Ast.Typ_wild(sk) -> 
        wild_f l sk
    | Ast.Typ_var(Ast.A_l((sk,tv),l')) -> 
        do_tvar (Tyvar.from_rope tv);
        { term = Typ_var(sk,Tyvar.from_rope tv); 
          locn = l'; 
          typ = { t = Tvar(Tyvar.from_rope tv); }; 
          rest = (); }
    | Ast.Typ_fn(typ1, sk, typ2) ->
        let st1 = typ_to_src_t wild_f do_tvar do_nvar d e typ1 in
        let st2 = typ_to_src_t wild_f do_tvar do_nvar d e typ2 in
          { term = Typ_fn(st1, sk, st2);
            locn = l; 
            typ = { t = Tfn(st1.typ,st2.typ) };
            rest = (); }
    | Ast.Typ_tup(typs) ->
        let typs = Seplist.from_list typs in
        let sts = Seplist.map (typ_to_src_t wild_f do_tvar do_nvar d e) typs in
          { term = Typ_tup(sts); 
            locn = l; 
            typ = { t = Ttup(Seplist.to_list_map annot_to_typ sts) };
            rest = (); }
    | Ast.Typ_app(i,typs) ->
        let p = lookup_p "constructor" e i in
          begin
            match Pfmap.apply d p with
              | None -> assert false
              | Some(Tc_type(td)) ->
                  if List.length td.type_tparams = List.length typs then
                    let sts = 
                      List.map (typ_to_src_t wild_f do_tvar do_nvar d e) typs 
                    in
                    let id = {id_path = Id_some (Ident.from_id i); 
                              id_locn = (match i with Ast.Id(_,_,l) -> l);
                              descr = p;
                              instantiation = []; }
                    in
		      (List.iter2 (tnvar_app_check l i) td.type_tparams sts);
                      { term = Typ_app(id,sts);
                        locn = l;
                        typ = { t = Tapp(List.map annot_to_typ sts,p) };
                        rest = (); }
                  else
                    raise (Reporting_basic.err_type_pp l (Printf.sprintf "type constructor expected %d type arguments, given %d" 
                                   (List.length td.type_tparams)
                                   (List.length typs))
                      Ident.pp (Ident.from_id i))
              | Some(Tc_class _) ->
                  raise (Reporting_basic.err_type_pp l "type class used as type constructor" 
                    Ident.pp (Ident.from_id i))
          end
    | Ast.Typ_paren(sk1,typ,sk2) ->
        let st = typ_to_src_t wild_f do_tvar do_nvar d e typ in
        { term = Typ_paren(sk1,st,sk2); 
          locn = l; 
          typ = st.typ; 
          rest = (); }
    | Ast.Typ_Nexps(nexp) -> 
        let nexp' = nexp_to_src_nexp do_nvar nexp in
        { term = Typ_len(nexp');
          locn = l;
          typ = {t = Tne(nexp'.nt);};
          rest=(); }

(*Permits only in, out, and the type of the witness, and enforces that it otherwise matches the relation type *)

(* It's easier if we realise that there are two very distinct cases :
  - either we are in the "spine" composed of in, out, ...
  - or we are in the last part, containing extra information
*)
let typ_to_src_t_indreln wit (d : type_defs) (e : local_env) (typt : Types.t) typ : src_t =
  let dest_id (Ast.Id(path,xl,l0) as i) =
    let n = Name.strip_lskip (Name.from_x xl) in
    (Name.to_string n,
     {id_path = Id_some (Ident.from_id i);
      id_locn = l0;
      descr = Path.mk_path [] n;
      instantiation = []; })
  in
  let rec compare_spine typt (Ast.Typ_l(typ,l) as typ') =
    match typt.t, typ with
      | Tfn(t1,t2), Ast.Typ_fn(typ1, sk, typ2) -> 
        let st1 = compare_io t1 typ1 in
        let st2 = compare_spine t2 typ2 in
        { term = Typ_fn(st1, sk, st2);
          locn = l;
          typ = { t = Tfn(st1.typ, st2.typ) };
          rest = (); }
      | Tfn(_,{t=Tfn(_,_)}), _ ->
        raise (Reporting_basic.err_type l "Too few arguments in indrel function specification (expecting an arrow here)")
      | Tfn(t1, _t2), _ -> compare_io t1 typ' (* _t2 is assumed to be bool *)
      | _ -> compare_end typt typ'
  and compare_io _ (Ast.Typ_l(typ,l)) = 
    match typ with
      | Ast.Typ_app(i, []) ->
        let n, id = dest_id i in
        let p = Path.mk_path [] (Name.from_string n) in
        if n = "input" || n = "output"
        then { term = Typ_app(id, []);
               locn = l;
               typ = { t = Tapp([], p) };
               rest = (); }
        else raise (Reporting_basic.err_type l "Only input or output may be used here") 
      | _ -> raise (Reporting_basic.err_type l "Only input or output may be used here")
  and compare_wu (Ast.Typ_l(typ,l)) =
      match typ with
      | Ast.Typ_app(i, []) -> 
        let n, id = dest_id i in
        let p = lookup_p "constructor" e i in
        begin match wit with
          | _ when Path.compare p Path.unitpath = 0 -> ()
          | Some(wit_p) when Path.compare p wit_p = 0 -> ()
          | _ -> raise (Reporting_basic.err_type_pp l "Expected unit or the witness" Path.pp p)
        end;
        { term = Typ_app({id with descr = p},[]);
          locn = l;
          typ = { t = Tapp([],p) };
          rest = (); }
      | _ -> raise (Reporting_basic.err_type l "Expected unit or the witness")
  and compare_end _ (Ast.Typ_l(typ,l) as typ') = 
   (* The other type should be bool, we don't check that *) 
   try compare_wu typ' 
    with _ -> 
      match typ with
        | Ast.Typ_app(i, (([] | [_]) as typs)) ->
          begin match dest_id i with
            | ("list"|"unique"|"pure"|"option") as n , id ->
              let sub = List.map compare_wu typs in
              { term = Typ_app(id, sub);
                locn = l;
                typ = { t = Tapp(List.map (fun x -> x.typ) sub, 
                                 Path.mk_path [] (Name.from_string n)) }; 
                rest = (); }
            | _ -> raise (Reporting_basic.err_type l "Expected list, unique, pure, option, unit or witness")
          end
        | _ -> raise (Reporting_basic.err_type l "Expected list, unique, pure, option, unit or witness")
  in
  compare_spine typt typ

(* Corresponds to judgment check_lit '|- lit : t' *)
let check_lit (Ast.Lit_l(lit,l)) =
  let annot (lit : lit_aux) (t : t) : lit = 
    { term = lit; locn = l; typ = t; rest = (); } 
  in 
  match lit with
    | Ast.L_true(sk) -> annot (L_true(sk)) { t = Tapp([], Path.boolpath) }
    | Ast.L_false(sk) -> annot (L_false(sk)) { t = Tapp([], Path.boolpath) }
    | Ast.L_num(sk,i) -> annot (L_num(sk,i)) { t = Tapp([], Path.numpath) }
    | Ast.L_string(sk,i) ->
        annot (L_string(sk,i)) { t = Tapp([], Path.stringpath) }
    | Ast.L_unit(sk1,sk2) ->
        annot (L_unit(sk1,sk2)) { t = Tapp([], Path.unitpath) }
    | Ast.L_bin(sk,i) ->
        let bit = { t = Tapp([], Path.bitpath) } in
        let len = { t = Tne( { nexp = Nconst(String.length i)} ) } in
        annot (L_vector(sk,"0b",i)) { t = Tapp([bit;len], Path.vectorpath) }
    | Ast.L_hex(sk,i) ->
        let bit = { t = Tapp([], Path.bitpath) } in
        let len = { t = Tne( { nexp = Nconst(String.length i * 4)} ) } in
        annot (L_vector(sk, "0x", i)) { t = Tapp([bit;len], Path.vectorpath) }
    | Ast.L_zero(sk) -> annot (L_zero(sk)) { t = Tapp([], Path.bitpath) }
    | Ast.L_one(sk) -> annot (L_one(sk)) { t = Tapp([], Path.bitpath) }

let check_dup_field_names (c_env : c_env) (fns : (const_descr_ref * Ast.l) list) : unit = 
  match DupRefs.duplicates fns with
    | DupRefs.Has_dups(f, l) ->
        let fd = c_env_lookup l c_env f in
        let n = Path.get_name fd.const_binding in
        raise (Reporting_basic.err_type_pp l "duplicate field name" 
          (fun fmt x -> Format.fprintf fmt "%a" Name.pp x)
          n)
    | _ -> ()

  (* Ensures that a monad operator is bound to a value constant that has no
   * class or length constraints and that has no length type parameters *)
  let check_const_for_do (mid : mod_descr id) (c_env : c_env) (v_env : v_env) (name : string) : 
    Tyvar.t list * t =
    let error_path = mid.descr.mod_binding in    
      match Nfmap.apply v_env (Name.from_rope (r name)) with
        | None ->
            raise (Reporting_basic.err_type_pp mid.id_locn (Printf.sprintf "monad module missing %s" name)
              Path.pp error_path)
        | Some(c) ->
            let c_d = c_env_lookup mid.id_locn c_env c in
            if c_d.const_class <> [] then
              raise (Reporting_basic.err_type_pp mid.id_locn (Printf.sprintf "monad operator %s has class constraints" name) 
                Path.pp error_path)
            else if c_d.const_ranges <> [] then
              raise (Reporting_basic.err_type_pp mid.id_locn (Printf.sprintf "monad operator %s has length constraints" name) 
                Path.pp error_path)
            else
              (List.map
                 (function 
                   | Nv _ -> 
                       raise (Reporting_basic.err_type_pp mid.id_locn (Printf.sprintf "monad operator %s has length variable type parameters" name) 
                         Path.pp error_path)
                   | Ty(v) -> v)
                 c_d.const_tparams,
               c_d.const_type)

(* Finds a type class's path, and its methods, in the current enviroment, given
 * its name. *)
let lookup_class_p (ctxt : defn_ctxt) (id : Ast.id) : Path.t * Types.tnvar * (Name.t * t) list = 
  let p = lookup_p "class" ctxt.cur_env id in
    match Pfmap.apply ctxt.all_tdefs p with
      | None -> assert false
      | Some(Tc_class(tv,methods)) -> (p, tv,methods)
      | Some(Tc_type _) ->
          raise (Reporting_basic.err_type_pp (match id with Ast.Id(_,_,l) -> l)
            "type constructor used as type class" Ident.pp (Ident.from_id id))

let ast_tnvar_to_tnvar (tnvar : Ast.tnvar) : Typed_ast.tnvar =
  match tnvar with
    | (Ast.Avl(Ast.A_l((sk,tv),l))) -> Tn_A(sk,tv,l)
    | (Ast.Nvl(Ast.N_l((sk,nv),l))) -> Tn_N(sk,nv,l)

let tvs_to_set (tvs : (Types.tnvar * Ast.l) list) : TNset.t =
  match DupTvs.duplicates (List.map fst tvs) with
    | DupTvs.Has_dups(tv) ->
        let (tv',l) = 
          List.find (fun (tv',_) -> TNvar.compare tv tv' = 0) tvs
        in
          raise (Reporting_basic.err_type_pp l "duplicate type variable" TNvar.pp tv')
    | DupTvs.No_dups(tvs_set) ->
        tvs_set

let anon_error l = 
  raise (Reporting_basic.err_type l "anonymous types not permitted here: _")

let rec check_free_tvs (tvs : TNset.t) (Ast.Typ_l(t,l)) : unit =
  match t with
    | Ast.Typ_wild _ ->
        anon_error l
    | Ast.Typ_var(Ast.A_l((t,x),l)) ->
       if TNset.mem (Ty (Tyvar.from_rope x)) tvs then
        ()
       else
        raise (Reporting_basic.err_type_pp l "unbound type variable" 
          Tyvar.pp (Tyvar.from_rope x))
    | Ast.Typ_fn(t1,_,t2) -> 
        check_free_tvs tvs t1; check_free_tvs tvs t2
    | Ast.Typ_tup(ts) -> 
        List.iter (check_free_tvs tvs) (List.map fst ts)
    | Ast.Typ_Nexps(n) -> check_free_ns tvs n
    | Ast.Typ_app(_,ts) -> 
        List.iter (check_free_tvs tvs) ts
    | Ast.Typ_paren(_,t,_) -> 
        check_free_tvs tvs t
and check_free_ns (nvs: TNset.t) (Ast.Length_l(nexp,l)) : unit =
  match nexp with
   | Ast.Nexp_var((_,x)) ->
       if TNset.mem (Nv (Nvar.from_rope x)) nvs then
        ()
       else
        raise (Reporting_basic.err_type_pp l "unbound length variable" Nvar.pp (Nvar.from_rope x))
   | Ast.Nexp_constant _ -> ()
   | Ast.Nexp_sum(n1,_,n2) | Ast.Nexp_times(n1,_,n2) -> check_free_ns nvs n1 ; check_free_ns nvs n2
   | Ast.Nexp_paren(_,n,_) -> check_free_ns nvs n

(* Process the "forall 'a. (C 'a) =>" part of a type,  Returns the bound
 * variables both as a list and as a set *)
let check_constraint_prefix (ctxt : defn_ctxt) 
      : Ast.c_pre -> 
        constraint_prefix option * 
        Types.tnvar list * 
        TNset.t * 
        ((Path.t * Types.tnvar) list * Types.range list) =
  let check_class_constraints c env =
   List.map
    (fun (Ast.C(id, tnv),sk) ->
    let tnv' = ast_tnvar_to_tnvar tnv in
    let (tnv'',l) = tnvar_to_types_tnvar tnv' in
    let (p,_,_) = lookup_class_p ctxt id in
    begin
      if TNset.mem tnv'' env then
         ()
      else
         raise (Reporting_basic.err_type_pp l "unbound type variable" pp_tnvar tnv'')
    end;
      (((Ident.from_id id, tnv'), sk),
       (p, tnv'')))
    c
  in
  let check_range_constraints rs env =
   List.map (fun (Ast.Range_l(r,l),sk) -> 
      match r with
       | Ast.Bounded(n1,sk1,n2) -> 
         let n1,n2 = nexp_to_src_nexp ignore n1, nexp_to_src_nexp ignore n2 in
         ((GtEq(l,n1,sk1,n2),sk),mk_gt_than l n1.nt n2.nt)
       | Ast.Fixed(n1,sk1,n2) -> 
         let n1,n2 = nexp_to_src_nexp ignore n1, nexp_to_src_nexp ignore n2 in
         ((Eq(l,n1,sk1,n2),sk),mk_eq_to l n1.nt n2.nt))
   rs
  in                        
  function
    | Ast.C_pre_empty ->
        (None, [], TNset.empty, ([],[]))
    | Ast.C_pre_forall(sk1,tvs,sk2,Ast.Cs_empty) ->
        let tnvars = List.map ast_tnvar_to_tnvar tvs in
        let tnvars_types = List.map tnvar_to_types_tnvar tnvars in

          (Some(Cp_forall(sk1, 
                          tnvars, 
                          sk2, 
                          None)),  
           List.map fst tnvars_types,
           tvs_to_set tnvars_types,
           ([],[]))
    | Ast.C_pre_forall(sk1,tvs,sk2,crs) ->
        let tnvars = List.map ast_tnvar_to_tnvar tvs in
        let tnvars_types = List.map tnvar_to_types_tnvar tnvars in
        let tnvarset = tvs_to_set tnvars_types in
        let (c,sk3,r,sk4) = match crs with 
                             | Ast.Cs_empty -> assert false
                             | Ast.Cs_classes(c,sk3) -> c,None,[],sk3
                             | Ast.Cs_lengths(r,sk3) -> [], None, r, sk3
                             | Ast.Cs_both(c,sk3,r,sk4) -> c, Some sk3, r, sk4 in
        let constraints = 
          let cs = check_class_constraints c tnvarset in
          let rs = check_range_constraints r tnvarset in
            (Cs_list(Seplist.from_list (List.map fst cs),sk3,Seplist.from_list (List.map fst rs),sk4), (List.map snd cs, List.map snd rs))
        in
          (Some(Cp_forall(sk1, 
                          tnvars, 
                          sk2, 
                          Some(fst constraints))),
           List.map fst tnvars_types,
           tnvarset,
           snd constraints)

(* adds a type to p_env *)
let add_p_to_ctxt ctxt ((n:Name.t), ((ty_p:Path.t), (ty_l:Ast.l))) =
   if Nfmap.in_dom n ctxt.new_defs.p_env then
     raise (Reporting_basic.err_type_pp ty_l "duplicate type definition" Name.pp n)
   else
     ctxt_add (fun x -> x.p_env) (fun x y -> { x with p_env = y }) ctxt (n, (ty_p, ty_l))

(* adds a field to f_env *)
let add_f_to_ctxt ctxt ((n:Name.t), (r:const_descr_ref)) =
     ctxt_add (fun x -> x.f_env) (fun x y -> { x with f_env = y }) ctxt (n, r)

(* adds a constant to v_env *)
let add_v_to_ctxt ctxt ((n:Name.t), (r:const_descr_ref)) =
     ctxt_add (fun x -> x.v_env) (fun x y -> { x with v_env = y }) ctxt (n, r)

(* Update new and cumulative enviroments with a new module definition, after
 * first checking that its name doesn't clash with another module definition in
 * the same definition sequence.  It can have the same name as another module
 * globally. *)
let add_m_to_ctxt (l : Ast.l) (ctxt : defn_ctxt) (k : Name.t) (v : mod_descr)
      : defn_ctxt = 
    if Nfmap.in_dom k ctxt.new_defs.m_env then
      raise (Reporting_basic.err_type_pp l "duplicate module definition" Name.pp k)
    else
      ctxt_add 
        (fun x -> x.m_env) 
        (fun x y -> { x with m_env = y }) 
        ctxt 
        (k,v)

(* Add a lemma name to the context *)
let add_lemma_to_ctxt (ctxt : defn_ctxt) (n : Name.t)  
      : defn_ctxt =
  { ctxt with lemmata_labels = NameSet.add n ctxt.lemmata_labels; }


(* We split the environment between top-level and lexically nested binders, and
 * inside of expressions, only the lexical environment can be extended, we
 * parameterize the entire expression-level checking apparatus over the
 * top-level environment.  This contrasts with the formal type system where
 * Delta and E get passed around.  The Make_checker functor also instantiates
 * the state for type inference, so checking of different expressions doesn't
 * interfere with each other.  We also imperatively collect class constraints
 * instead of passing them around as the formal type system does *)

module type Expr_checker = sig
  val check_lem_exp : lex_env -> Ast.l -> Ast.exp -> Types.t -> (exp * typ_constraints)

  val check_letbind : 
    (* Should be None, unless checking a method definition in an instance.  Then
     * it should contain the type that the instance is at.  In this case the
     * returned constraints and type variables must be empty. *)
    t option ->
    (* The set of targets that this definition is for *)
    Targetset.t option ->
    Ast.l ->
    Ast.letbind -> 
    letbind * 
    (* The types of the bindings *)
    pat_env * 
    (* The type variabes, and class constraints on them used in typechecking the
     * let binding.  Must be empty when the optional type argument is Some *)
    typ_constraints

  (* As in the comments on check letbind above *)
  val check_funs : 
    t option ->
    Targetset.t option ->
    Ast.l ->
    Ast.funcl lskips_seplist -> 
    (name_lskips_annot * pat list * (lskips * src_t) option * lskips * exp) lskips_seplist * 
    pat_env * 
    typ_constraints

  (* As in the comments on check letbind above, but cannot be an instance
   * method definition *)
  val check_indrels : 
    defn_ctxt ->
    Name.t list -> 
    Targetset.t option ->
    Ast.l ->
    (Ast.indreln_name * lskips) list ->
    (Ast.rule * lskips) list -> 
    indreln_name lskips_seplist *
    indreln_rule lskips_seplist * 
    pat_env *
    typ_constraints

end

let unsat_constraint_err l = function
  | [] -> ()
  | cs ->
      let t1 = 
        Pp.pp_to_string 
          (fun ppf -> 
             (Pp.lst "@\nand@\n" pp_class_constraint) ppf cs)
      in
        raise (Reporting_basic.err_type l ("unsatisfied type class constraints:\n" ^ t1))

module Make_checker(T : sig 
                      (* The backend targets that each identifier use must be
                       * defined for *)
                      val targets : Targetset.t
                      (* The current top-level environment *)
                      val e : env 
                      (* The environment so-far of the module we're defining *)
                      val new_module_env : local_env
                      include Global_defs 
                    end) : Expr_checker = struct

  module C = Constraint(T)
  module A = Exps_in_context(struct let env_opt = None let avoid = None end)

  (* An identifier instantiated to fresh type variables *)
  let make_new_id ((id : Ident.t), l) (tvs : Types.tnvar list) (descr : 'a) : 'a id =
    let ts_inst = List.map (fun v -> match v with | Ty _ -> C.new_type () | Nv _ -> {t = Tne(C.new_nexp ())}) tvs in
      { id_path = Id_some id; 
        id_locn = l;
        descr = descr; 
        instantiation = ts_inst; }

  (* Assumes that mp refers to only modules and xl a field name.  Corresponds to
   * judgment inst_field 'Delta,E |- field id : t_args p -> t gives (x of
   * names)'.  Instantiates the field descriptor with fresh type variables, also
   * calculates the type of the field as a function from the record type to the
   * field's type.
   *)
  let check_field (Ast.Id(mp,xl,l) as i) 
        : (const_descr_ref id * Types.t) * Ast.l =
    let env = path_lookup l T.e.local_env (List.map (fun (xl,_) -> xl_to_nl xl) mp) in
    match Nfmap.apply env.f_env (Name.strip_lskip (Name.from_x xl)) with
        | None ->
            begin
              match Nfmap.apply env.v_env (Name.strip_lskip (Name.from_x xl)) with
                | None ->
                    raise (Reporting_basic.err_type_pp l "unbound field name" 
                      Ident.pp (Ident.from_id i))
                | Some(c) ->
                    let c_d = c_env_lookup l T.e.c_env c in
                    if c_d.env_tag = K_method then
                      raise (Reporting_basic.err_type_pp l "method name used as a field name"
                        Ident.pp (Ident.from_id i))
                    else if c_d.env_tag = K_constr then
                      raise (Reporting_basic.err_type_pp l "constructor name used as a field name"
                      Ident.pp (Ident.from_id i))
                    else
                      raise (Reporting_basic.err_type_pp l "top level variable binding used as a field name"
                        Ident.pp (Ident.from_id i))
            end
        | Some(f) ->
          begin
            let id_l = id_to_identl i in
            let (f_field_arg, f_tconstr, f_d) = dest_field_types l T.e f in
            let new_id = make_new_id id_l f_d.const_tparams f in
            let trec = { t = Tapp(new_id.instantiation,f_tconstr) } in
            let subst = 
              TNfmap.from_list2 f_d.const_tparams new_id.instantiation 
            in
            let tfield = type_subst subst f_field_arg in
            let t = { t = Tfn(trec, tfield) } in
            let a = C.new_type () in
              C.equate_types new_id.id_locn "field expression 1" a t;
              ((new_id, a), l)
          end

  (* Instantiates a top-level constant descriptor with fresh type variables,
   * also calculates its type.  Corresponds to judgment inst_val 'Delta,E |- val
   * id : t gives Sigma', except that that also looks up the descriptor. Moreover,
   * it computes the number of arguments this constant expects *)
  let inst_const id_l (env : env) (c : const_descr_ref) : const_descr_ref id * t =
    let cd = c_env_lookup (snd id_l) env.c_env c in
    let new_id = make_new_id id_l cd.const_tparams c in
    let subst = TNfmap.from_list2 cd.const_tparams new_id.instantiation in
    let t = type_subst subst cd.const_type in
    let a = C.new_type () in
      C.equate_types new_id.id_locn "constant use" a t;
      List.iter 
        (fun (p, tv) -> 
           C.add_constraint p (type_subst subst (tnvar_to_type tv))) 
        cd.const_class;
      List.iter
         (fun r -> C.add_length_constraint (range_with r (nexp_subst subst (range_of_n r)))) 
         cd.const_ranges;
      (new_id, a)

  let add_binding (pat_e : pat_env) ((v : Name.lskips_t), (l : Ast.l)) (t : t) 
        : pat_env =
    if Nfmap.in_dom (Name.strip_lskip v) pat_e then
      raise (Reporting_basic.err_type_pp l "duplicate binding" Name.pp (Name.strip_lskip v))
    else
      Nfmap.insert pat_e (Name.strip_lskip v,(t,l))

  let build_wild l sk =
    { term = Typ_wild(sk); locn = l; typ = C.new_type (); rest = (); }

  (* Corresponds to judgment check_pat 'Delta,E,E_l1 |- pat : t gives E_l2' *)
  let rec check_pat (l_e : lex_env) (Ast.Pat_l(p,l)) (acc : pat_env) 
        : pat * pat_env = 
    let ret_type = C.new_type () in
    let rt = Some(ret_type) in
      match p with
        | Ast.P_wild(sk) -> 
            let a = C.new_type () in
              C.equate_types l "underscore pattern" ret_type a;
              (A.mk_pwild l sk ret_type, acc)
        | Ast.P_as(s1,p, s2, xl,s3) -> 
            let nl = xl_to_nl xl in
            let (pat,pat_e) = check_pat l_e p acc in
            let ax = C.new_type () in
              C.equate_types (snd nl) "as pattern" ax pat.typ;
              C.equate_types l "as pattern" pat.typ ret_type;
              (A.mk_pas l s1 pat s2 nl s3 rt, add_binding pat_e nl ax)
        | Ast.P_typ(sk1,p,sk2,typ,sk3) ->
            let (pat,pat_e) = check_pat l_e p acc in
            let src_t = 
              typ_to_src_t build_wild C.add_tyvar C.add_nvar T.d T.e.local_env typ
            in
              C.equate_types l "type-annotated pattern" src_t.typ pat.typ;
              C.equate_types l "type-annotated pattern" src_t.typ ret_type;
              (A.mk_ptyp l sk1 pat sk2 src_t sk3 rt, pat_e)
        | Ast.P_app(Ast.Id(mp,xl,l'') as i, ps) ->
            let l' = Ast.xl_to_l xl in
            let e = path_lookup l' T.e.local_env (List.map (fun (xl,_) -> xl_to_nl xl) mp) in
            let const_lookup_res = Nfmap.apply e.v_env (Name.strip_lskip (Name.from_x xl)) in

            (** Try to handle it as a construtor, if success, then return Some, otherwise None
                and handle as variable *)
            let constr_res_opt = begin
                match const_lookup_res with
                   | Some(c) when (lookup_l l_e mp (Name.from_x xl) = None) ->
                      (* i is bound to a constructor that is not lexically
                       * shadowed, this corresponds to the
                       * check_pat_aux_ident_constr case *)

                      let cd = c_env_lookup (snd (id_to_identl i)) T.e.c_env c in
                      let (arg_ts, base_t) = Types.strip_fn_type (Some T.e.t_env) cd.const_type in
                      let is_constr = (List.length (type_defs_get_constr_families l' T.d base_t c) > 0) in
                      let (pats,pat_e) = check_pats l_e acc ps in
                        if (List.length pats <> List.length arg_ts) || (not is_constr) then (
                          if (List.length pats == 0) then (*handle as var*) None else
                          raise (Reporting_basic.err_type_pp l' 
                             (if is_constr then
                               (Printf.sprintf "constructor pattern expected %d arguments, given %d"
                                 (List.length arg_ts) (List.length pats)) 
                              else "non-constructor pattern given arguments")
                            Ident.pp (Ident.from_id i))
                        ) else (
                          let (id,t) = inst_const (id_to_identl i) T.e c in
                          C.equate_types l'' "constructor pattern" t 
                            (multi_fun (List.map annot_to_typ pats) ret_type);
                          Some (A.mk_pconst l id pats rt, pat_e)
                        )
                   | _ -> None
              end in
            begin 
                match constr_res_opt with 
                   | Some res -> res 
                   | None -> begin
                      (* the check_pat_aux_var case *)
                      match mp with
                        | [] ->
                            if ps <> [] then
                              raise (Reporting_basic.err_type_pp l' "non-constructor pattern given arguments" 
                                Ident.pp (Ident.from_id i))
                            else
                              let ax = C.new_type () in
                              let n = Name.from_x xl in
                                C.equate_types l'' "constructor pattern" ret_type ax;
                                (A.mk_pvar l n ret_type, 
                                 add_binding acc (n,l') ax)
                        | _ ->
                            raise (Reporting_basic.err_type_pp l' "non-constructor pattern has a module path" 
                              Ident.pp (Ident.from_id i))
                      end
              end
        | Ast.P_record(sk1,ips,sk2,term_semi,sk3) ->
            let fpats = Seplist.from_list_suffix ips sk2 term_semi in
            let a = C.new_type () in
            let (checked_pats, pat_e) = 
              Seplist.map_acc_left (check_fpat a l_e) acc fpats 
            in
              check_dup_field_names T.e.c_env
                (Seplist.to_list_map snd checked_pats);
              C.equate_types l "record pattern" a ret_type;
              (A.mk_precord l sk1 (Seplist.map fst checked_pats) sk3 rt,
               pat_e)
        | Ast.P_tup(sk1,ps,sk2) -> 
            let pats = Seplist.from_list ps in
            let (pats,pat_e) = 
              Seplist.map_acc_left (check_pat l_e) acc pats
            in
              C.equate_types l "tuple pattern" ret_type 
                { t = Ttup(Seplist.to_list_map annot_to_typ pats) };
              (A.mk_ptup l sk1 pats sk2 rt, pat_e)
        | Ast.P_list(sk1,ps,sk2,semi,sk3) -> 
            let pats = Seplist.from_list_suffix ps sk2 semi in
            let (pats,pat_e) = 
              Seplist.map_acc_left (check_pat l_e) acc pats
            in
            let a = C.new_type () in
              Seplist.iter (fun pat -> C.equate_types l "list pattern" a pat.typ) pats;
              C.equate_types l "list pattern" ret_type { t = Tapp([a], Path.listpath) };
              (A.mk_plist l sk1 pats sk3 ret_type, pat_e)
	| Ast.P_vector(sk1,ps,sk2,semi,sk3) -> 
           let pats = Seplist.from_list_suffix ps sk2 semi in
           let (pats,pat_e) = 
             Seplist.map_acc_left (check_pat l_e) acc pats
           in
           let a = C.new_type () in
             Seplist.iter (fun pat -> C.equate_types l "vector pattern" a pat.typ) pats;
             let len = { t = Tne({ nexp = Nconst( Seplist.length pats )} ) } in
             C.equate_types l "vector pattern" ret_type { t = Tapp([a;len], Path.vectorpath) };
             (A.mk_pvector l sk1 pats sk3 ret_type, pat_e)
        | Ast.P_vectorC(sk1,ps,sk2) -> 
            let (pats,pat_e) = List.fold_left (fun (l,acc) p ->
                                                 let (p,a) = (check_pat l_e) p acc in
                                                 (p::l, a)) ([], acc) ps in
            let pats = List.rev pats in
            let a = C.new_type() in
            let lens =
              List.fold_left (fun lens pat -> 
                                let c = C.new_nexp () in
                                C.equate_types l "vector concatenation pattern" { t = Tapp([a;{t=Tne(c)}],Path.vectorpath) } pat.typ;
                                c::lens) [] pats in
              let len = { t = Tne( nexp_from_list (List.rev lens) ) } in
              C.equate_types l "vector concatenation pattern" ret_type { t = Tapp([a;len],Path.vectorpath) };
              (A.mk_pvectorc l sk1 pats sk2 ret_type, pat_e)
        | Ast.P_paren(sk1,p,sk2) -> 
            let (pat,pat_e) = check_pat l_e p acc in
              C.equate_types l "paren pattern" ret_type pat.typ;
              (A.mk_pparen l sk1 pat sk2 rt, pat_e)
        | Ast.P_cons(p1,sk,p2) ->
            let (pat1,pat_e) = check_pat l_e p1 acc in
            let (pat2,pat_e) = check_pat l_e p2 pat_e in
              C.equate_types l ":: pattern" ret_type { t = Tapp([pat1.typ], Path.listpath) };
              C.equate_types l ":: pattern" ret_type pat2.typ;
              (A.mk_pcons l pat1 sk pat2 rt, pat_e)
        | Ast.P_num_add(xl,sk1,sk2,i) ->
            let nl = xl_to_nl xl in
            let ax = C.new_type () in
            C.equate_types l "addition pattern" ret_type { t = Tapp([], Path.numpath) };
            C.equate_types (snd nl) "addition pattern" ax ret_type;
          (A.mk_pnum_add l nl sk1 sk2 i rt, add_binding acc nl ax)
        | Ast.P_lit(lit) ->
            let lit = check_lit lit in
              C.equate_types l "literal pattern" ret_type lit.typ;
              (A.mk_plit l lit rt, acc)

  and check_fpat a (l_e : lex_env) (Ast.Fpat(id,sk,p,l)) (acc : pat_env)  
                : (((const_descr_ref id * lskips * pat) * (const_descr_ref * Ast.l)) * pat_env)=
    let (p,acc) = check_pat l_e p acc in
    let ((id,t),l') = check_field id in
      C.equate_types l "field pattern" t { t = Tfn(a,p.typ) };
      (((id,sk,p),(id.descr, l')), acc)

  and check_pats (l_e : lex_env) (acc : pat_env) (ps : Ast.pat list) 
                : pat list * pat_env =
    List.fold_right 
      (fun p (pats,pat_e) -> 
         let (pat,pat_e) = check_pat l_e p pat_e in
           (pat::pats,pat_e))
      ps
      ([],acc) 

  (* Given an identifier, start at the left and follow it as a module path until
   * the first field/value reference (according to for_field) is encountered.
   * Return the prefix including that reference as a separate identifier.  If a
   * lex_env is supplied, check for value reference in it for the first name
   * only.
   *
   * In the formal type system, we don't calculate this split, but instead use
   * the id_field 'E |- id field' and id_value 'E |- id value' judgments to
   * ensure that the id is one that would be returned by this function.  That
   * is, the id follows the module reference whenever there is ambiguity.  *)
  let rec get_id_mod_prefix (for_field : bool) (check_le : lex_env option) 
        (env : local_env) (Ast.Id(mp,xl,l_add)) 
        (prefix_acc : (Ast.x_l * Ast.lex_skips) list) : Ast.id * (Ast.lex_skips * Ast.id) option =
    match mp with
      | [] -> 
          let n = Name.strip_lskip (Name.from_x xl) in
          let unbound = 
            if for_field then 
              Nfmap.apply env.f_env n = None 
            else 
              (Nfmap.apply env.v_env n = None &&
               (match check_le with 
                  | None -> true 
                  | Some(le) -> Nfmap.apply le n = None))
          in
          let id = Ast.Id(List.rev prefix_acc,xl,l_add) in
            if unbound then
              raise (Reporting_basic.err_type_pp (Ast.xl_to_l xl) 
                (if for_field then "unbound field name" else "unbound variable")
                Ident.pp (Ident.from_id id))
            else
              (id, None)
      | (xl',sk)::mp' ->
          let n = Name.strip_lskip (Name.from_x xl') in
          let unbound = 
            if for_field then 
              Nfmap.apply env.f_env n = None 
            else 
              (Nfmap.apply env.v_env n = None &&
               (match check_le with 
                  | None -> true 
                  | Some(le) -> Nfmap.apply le n = None))
          in
          let id = Ast.Id(List.rev prefix_acc,xl',l_add) in
            if unbound then
              begin
                match Nfmap.apply env.m_env n with
                  | None ->
                      raise (Reporting_basic.err_type_pp (Ast.xl_to_l xl') 
                        ("unbound module name or " ^
                         if for_field then "field name" else "variable")
                        Ident.pp (Ident.from_id id))
                  | Some(md) ->
                      get_id_mod_prefix for_field None md.mod_env
                        (Ast.Id(mp',xl,l_add)) 
                        ((xl',sk)::prefix_acc)
              end
            else
              (id, Some(sk,Ast.Id(mp',xl,l_add)))


  (* Chop up an identifier into a list of record projections.  Each projection
   * can be an identifier with a non-empty module path *)
  let rec disambiguate_projections sk (id : Ast.id) 
        : (Ast.lex_skips * Ast.id) list =
    match get_id_mod_prefix true None T.e.local_env id [] with
      | (id,None) -> [(sk,id)]
      | (id1,Some(sk',id2)) -> (sk,id1)::disambiguate_projections sk' id2

  (* Figures out which '.'s in an identifier are actually record projections.
   * This is ambiguous in the source since field names can be '.' separated
   * module paths *)
  let disambiguate_id (le : lex_env) (id : Ast.id) 
        : Ast.id * (Ast.lex_skips * Ast.id) list =
    match get_id_mod_prefix false (Some(le)) T.e.local_env id [] with
      | (id,None) -> (id, [])
      | (id1,Some(sk,id2)) ->
          (id1, disambiguate_projections sk id2)

  let rec check_all_fields (exp : Typed_ast.exp) 
        (fids : (Ast.lex_skips * Ast.id) list) =
    match fids with
      | [] ->
          exp
      | (sk,fid)::fids ->
          let ((id,t),l) = check_field fid in
          let ret_type = C.new_type () in
            C.equate_types l "field access" t { t = Tfn(exp_to_typ exp, ret_type) };
            check_all_fields (A.mk_field l exp sk id (Some ret_type)) fids

  (* Corresponds to inst_val 'D,E |- val id : t gives S' and the 
  * var and val cases of check_exp_aux *)
  let check_val (l_e : lex_env) (mp : (Ast.x_l * Ast.lex_skips) list) 
        (n : Name.lskips_t) (l : Ast.l) : exp =    
    match lookup_l l_e mp n with
      | Some(t,l,n) -> 
          (* The name is bound to a local variable, so return a variable *)
          A.mk_var l n t
      | None -> 
          (* check whether the name is bound to a constant (excluding fields) *)
          let mp' = List.map (fun (xl,_) -> xl_to_nl xl) mp in
          let e = path_lookup l T.e.local_env mp' in
            match Nfmap.apply e.v_env (Name.strip_lskip n) with
              | None    -> 
                  (* not bound to a constant either, so it's unbound *)
                  raise (Reporting_basic.err_type_pp l "unbound variable" Name.pp (Name.strip_lskip n))
              | Some(c) ->
                  (* its bound, but is it bound for the necessary targets? *)
                  let cd = c_env_lookup l T.e.c_env c in
                  let undefined_targets = Targetset.diff T.targets cd.const_targets in
                  if not (Targetset.is_empty undefined_targets) then
                     raise (Reporting_basic.err_type_pp l (Pp.pp_to_string (fun ppf -> 
                        Format.fprintf ppf
                           "unbound variable for targets {%a}"
                           (Pp.lst ";" (fun ppf t -> Pp.pp_str ppf (non_ident_target_to_string t)))
                           (Targetset.elements undefined_targets)
                        )) Name.pp (Name.strip_lskip n))                     
                  else ();

                  (* its bound for all the necessary targets, so lets return the constant *)
                  let mp'' = List.map (fun (xl,skips) -> (Name.from_x xl, skips)) mp in
                  let (id,t) = inst_const (Ident.mk_ident_ast mp'' n l, l) T.e c in
                    C.equate_types l "top-level binding use" t (C.new_type());
                    A.mk_const l id (Some(t))

  let check_id (l_e : lex_env) (Ast.Id(mp,xl,l_add) as id) : exp =
    (* We could type check and disambiguate at the same time, but that would
     * have a more complicated implementation, so we don't *)
    let (Ast.Id(mp,xl,l), fields) = disambiguate_id l_e id in
    let exp = check_val l_e mp (Name.from_x xl) l in
      check_all_fields exp fields

  (* Corresponds to judgment check_exp 'Delta,E,E_ |- exp : t gives Sigma' *)
  let rec check_exp (l_e : lex_env) (Ast.Expr_l(exp,l)) : exp =
    let ret_type = C.new_type () in
    let rt = Some(ret_type) in 
      match exp with
        | Ast.Ident(i) -> 
            let exp = check_id l_e i in
              C.equate_types l "identifier use" ret_type (exp_to_typ exp);
              exp
        | Ast.Nvar((sk,n)) -> 
            let nv = Nvar.from_rope(n) in
            C.add_nvar nv;
            A.mk_nvar_e l sk nv  { t = Tapp([], Path.numpath) }
        | Ast.Fun(sk,pse) -> 
            let (param_pats,sk',body_exp,t) = check_psexp l_e pse in
              C.equate_types l "fun expression" t ret_type;
              A.mk_fun l sk param_pats sk' body_exp rt
        | Ast.Function(sk,bar_sk,bar,pm,end_sk) -> 
            let pm = Seplist.from_list_prefix bar_sk bar pm in
            let res = 
              Seplist.map
                (fun pe ->
                   let (res,t) = check_pexp l_e pe in
                     C.equate_types l "function expression" t ret_type;
                     res)
                pm
            in
              A.mk_function l sk res end_sk rt
        | Ast.App(fn,arg) ->
            let fnexp = check_exp l_e fn in
            let argexp = check_exp l_e arg in
              C.equate_types l "application expression" { t = Tfn(exp_to_typ argexp,ret_type) } (exp_to_typ fnexp);
              A.mk_app l fnexp argexp rt
        | Ast.Infix(e1, xl, e2) ->
            let n = Name.from_ix xl in
            let id = check_val l_e [] n (Ast.ixl_to_l xl) in
            let arg1 = check_exp l_e e1 in
            let arg2 = check_exp l_e e2 in
              C.equate_types l 
                "infix expression"
                { t = Tfn(exp_to_typ arg1, { t = Tfn(exp_to_typ arg2,ret_type) }) }
                (exp_to_typ id);
              A.mk_infix l arg1 id arg2 rt
        | Ast.Record(sk1,r,sk2) ->
            let (res,t,given_fields) = check_fexps l_e r in
            let one_field = match given_fields with [] -> raise (Reporting_basic.err_type l "empty records, no fields given") | f::_ -> f in
            let all_fields = get_field_all_fields l T.e one_field in
            let missing_fields = Util.list_diff all_fields given_fields in
            if (Util.list_longer 0 missing_fields) then
              begin
                  (* get names of missing fields for error message *)
                  let field_get_name f_ref = begin
                     let f_d = c_env_lookup l T.e.c_env f_ref in
                     let f_path = f_d.const_binding in
                     Path.get_name f_path
                  end in
                  let names = List.map field_get_name missing_fields in
                  let names_string = Pp.pp_to_string (fun ppf -> (Pp.lst "@, @" Name.pp) ppf names) in
                  let message = Printf.sprintf "missing %s: %s" (if Util.list_longer 1 missing_fields then "fields" else "field") names_string in
                  raise (Reporting_basic.err_type l message)
              end;
              C.equate_types l "record expression" t ret_type;
              A.mk_record l sk1 res sk2 rt
        | Ast.Recup(sk1,e,sk2,r,sk3) ->
            let exp = check_exp l_e e in
            let (res,t,_) = check_fexps l_e r in
              C.equate_types l "record update expression" (exp_to_typ exp) t;
              C.equate_types l "record update expression" t ret_type;
              A.mk_recup l sk1 exp sk2 res sk3 rt
        | Ast.Field(e,sk,fid) ->
            let exp = check_exp l_e e in
            let fids = disambiguate_projections sk fid in
            let new_exp = check_all_fields exp fids in
              C.equate_types l "field expression 2" ret_type (exp_to_typ new_exp);
              new_exp
        | Ast.Case(sk1,e,sk2,bar_sk,bar,pm,l',sk3) ->
            let pm = Seplist.from_list_prefix bar_sk bar pm in
            let exp = check_exp l_e e in
            let a = C.new_type () in
            let res = 
              Seplist.map
                (fun pe ->
                   let (res,t) = check_pexp l_e pe in
                     C.equate_types l' "match expression" t a;
                     res)
                pm
            in
              C.equate_types l "match expression" a { t = Tfn(exp_to_typ exp,ret_type) };
              A.mk_case false l sk1 exp sk2 res sk3 rt
        | Ast.Typed(sk1,e,sk2,typ,sk3) ->
            let exp = check_exp l_e e in
            let src_t = typ_to_src_t build_wild C.add_tyvar C.add_nvar T.d T.e.local_env typ in
              C.equate_types l "type-annotated expression" src_t.typ (exp_to_typ exp);
              C.equate_types l "type-annotated expression" src_t.typ ret_type;
              A.mk_typed l sk1 exp sk2 src_t sk3 rt
        | Ast.Let(sk1,lb,sk2, body) -> 
            let (lb,pat_env) = check_letbind_internal l_e lb in
            let body_exp = check_exp (Nfmap.union l_e pat_env) body in
              C.equate_types l "let expression" ret_type (exp_to_typ body_exp);
              A.mk_let l sk1 lb sk2 body_exp rt
        | Ast.Tup(sk1,es,sk2) ->
            let es = Seplist.from_list es in
            let exps = Seplist.map (check_exp l_e) es in
              C.equate_types l "tuple expression" ret_type 
                { t = Ttup(Seplist.to_list_map exp_to_typ exps) };
              A.mk_tup l sk1 exps sk2 rt
        | Ast.Elist(sk1,es,sk3,semi,sk2) -> 
            let es = Seplist.from_list_suffix es sk3 semi in
            let exps = Seplist.map (check_exp l_e) es in
            let a = C.new_type () in
              Seplist.iter (fun exp -> C.equate_types l "list expression" a (exp_to_typ exp)) exps;
              C.equate_types l "list expression" ret_type { t = Tapp([a], Path.listpath) };
              A.mk_list l sk1 exps sk2 ret_type
        | Ast.Vector(sk1,es,sk3,semi,sk2) -> 
            let es = Seplist.from_list_suffix es sk3 semi in
            let exps = Seplist.map (check_exp l_e) es in
            let a = C.new_type () in
            let len = {t = Tne( { nexp=Nconst(Seplist.length exps)} ) }in
              Seplist.iter (fun exp -> C.equate_types l "vector expression" a (exp_to_typ exp)) exps;
              C.equate_types l "vector expression" ret_type { t = Tapp([a;len], Path.vectorpath) };
              A.mk_vector l sk1 exps sk2 ret_type
        | Ast.VAccess(e,sk1,nexp,sk2) -> 
            let exp = check_exp l_e e in
            let n = nexp_to_src_nexp C.add_nvar nexp in
            let vec_n = C.new_nexp () in
            let t = exp_to_typ exp in
              C.equate_types l "vector access expression" { t = Tapp([ ret_type;{t = Tne(vec_n)}],Path.vectorpath) } t;
              C.in_range l vec_n n.nt;
              A.mk_vaccess l exp sk1 n sk2 ret_type
        | Ast.VAccessR(e,sk1,n1,sk2,n2,sk3) -> 
            let exp = check_exp l_e e in
            let n1 = nexp_to_src_nexp C.add_nvar n1 in
            let n2 = nexp_to_src_nexp C.add_nvar n2 in
            let vec_n = C.new_nexp () in
            let vec_t = C.new_type () in
            let t = exp_to_typ exp in
              C.equate_types l "vector access expression" { t=Tapp([vec_t;{t = Tne(vec_n)}], Path.vectorpath) } t;
              C.in_range l n2.nt n1.nt;
              C.in_range l vec_n n2.nt;
              C.equate_types l "vector access expression" ret_type { t =Tapp([vec_t;{t = Tne({ nexp=Nadd(n2.nt,{nexp=Nneg(n1.nt)})})}], Path.vectorpath)};
              A.mk_vaccessr l exp sk1 n1 sk2 n2 sk3 ret_type 
        | Ast.Paren(sk1,e,sk2) ->
            let exp = check_exp l_e e in
              C.equate_types l "parenthesized expression" ret_type (exp_to_typ exp);
              A.mk_paren l sk1 exp sk2 rt
        | Ast.Begin(sk1,e,sk2) ->
            let exp = check_exp l_e e in
              C.equate_types l "begin expression" ret_type (exp_to_typ exp);
              A.mk_begin l sk1 exp sk2 rt
        | Ast.If(sk1,e1,sk2,e2,sk3,e3) ->
            let exp1 = check_exp l_e e1 in
            let exp2 = check_exp l_e e2 in
            let exp3 = check_exp l_e e3 in
              C.equate_types l "if expression" ret_type (exp_to_typ exp2);
              C.equate_types l "if expression" ret_type (exp_to_typ exp3);
              C.equate_types l "if expression" (exp_to_typ exp1) { t = Tapp([], Path.boolpath) };
              A.mk_if l sk1 exp1 sk2 exp2 sk3 exp3 rt
        | Ast.Cons(e1,sk,e2) ->
            let e = 
              check_exp l_e 
                (Ast.Expr_l(Ast.Infix(e1,Ast.SymX_l((sk,r"::"), l),e2), l))
            in 
              C.equate_types l ":: expression" ret_type (exp_to_typ e);
              e
        | Ast.Lit(lit) ->
            let lit = check_lit lit in
              C.equate_types l "literal expression" ret_type lit.typ;
              A.mk_lit l lit rt
        | Ast.Set(sk1,es,sk2,semi,sk3) -> 
            let es = Seplist.from_list_suffix es sk2 semi in
            let exps = Seplist.map (check_exp l_e) es in
            let a = C.new_type () in
              Seplist.iter (fun exp -> C.equate_types l "set expression" a (exp_to_typ exp)) exps;
              C.equate_types l "set expression" ret_type { t = Tapp([a], Path.setpath) };
              A.mk_set l sk1 exps sk3 ret_type
        | Ast.Setcomp(sk1,e1,sk2,e2,sk3) ->
            let not_shadowed n =
              not (Nfmap.in_dom n l_e) &&
              not (Nfmap.in_dom n T.e.local_env.v_env)
            in
            let vars = Ast_util.setcomp_bindings not_shadowed e1 in
            let new_vars = 
              NameSet.fold
                (fun v m -> Nfmap.insert m (v, (C.new_type (),l)))
                vars
                Nfmap.empty
            in
            let env = Nfmap.union l_e new_vars in
            let exp1 = check_exp env e1 in
            let exp2 = check_exp env e2 in
            let a = C.new_type () in
              C.equate_types l "set comprehension expression" (exp_to_typ exp2) { t = Tapp([], Path.boolpath) };
              C.equate_types l "set comprehension expression" (exp_to_typ exp1) a;
              C.equate_types l "set comprehension expression" ret_type { t = Tapp([a], Path.setpath) };
              A.mk_setcomp l sk1 exp1 sk2 exp2 sk3 vars rt
        | Ast.Setcomp_binding(sk1,e1,sk2,sk5,qbs,sk3,e2,sk4) ->
            let (quant_env,qbs) = check_qbs false l_e qbs in
            let env = Nfmap.union l_e quant_env in
            let exp1 = check_exp env e1 in
            let exp2 = check_exp env e2 in
            let a = C.new_type () in
              C.equate_types l "set comprehension expression" (exp_to_typ exp2) { t = Tapp([], Path.boolpath) };
              C.equate_types l "set comprehension expression" (exp_to_typ exp1) a;
              C.equate_types l "set comprehension expression" ret_type { t = Tapp([a], Path.setpath) };
              A.mk_comp_binding l false sk1 exp1 sk2 sk5 
                (List.rev qbs) sk3 exp2 sk4 rt
        | Ast.Quant(q,qbs,s,e) ->
            let (quant_env,qbs) = check_qbs false l_e qbs in
            let et = check_exp (Nfmap.union l_e quant_env) e in
              C.equate_types l "quantified expression" ret_type { t = Tapp([], Path.boolpath) };
              C.equate_types l "quantified expression" ret_type (exp_to_typ et);
              A.mk_quant l q (List.rev qbs) s et rt
        | Ast.Listcomp(sk1,e1,sk2,sk5,qbs,sk3,e2,sk4) ->
            let (quant_env,qbs) = check_qbs true l_e qbs in
            let env = Nfmap.union l_e quant_env in
            let exp1 = check_exp env e1 in
            let exp2 = check_exp env e2 in
            let a = C.new_type () in
              C.equate_types l "list comprehension expression" (exp_to_typ exp2) { t = Tapp([], Path.boolpath) };
              C.equate_types l "list comprehension expression" (exp_to_typ exp1) a;
              C.equate_types l "list comprehension expression" ret_type { t = Tapp([a], Path.listpath) };
              A.mk_comp_binding l true sk1 exp1 sk2 sk5 
                (List.rev qbs) sk3 exp2 sk4 rt
        | Ast.Do(sk1,mn,lns,sk2,e,sk3) ->
            let mod_descr = lookup_mod T.e.local_env mn in
            let mod_env = mod_descr.mod_env in
            let mod_id = 
              { id_path = Id_some (Ident.from_id mn);
                id_locn = (match mn with Ast.Id(_,_,l) -> l);
                descr = mod_descr;
                instantiation = []; }
            in
            let monad_type_ctor = 
              match Nfmap.apply mod_env.p_env (Name.from_rope (r "t")) with
                | None ->
                    raise (Reporting_basic.err_type_pp mod_id.id_locn "monad module missing type t"
                      Ident.pp (Ident.from_id mn))
                | Some((p,l)) -> p
            in
            let () =
              (* Check that the module contains an appropriate type "t" to be
               * the monad. *)
              match Pfmap.apply T.d monad_type_ctor with
                | None -> assert false
                | Some(Tc_class _) ->
                    raise (Reporting_basic.err_type_pp mod_id.id_locn "type class used as monad" 
                      Path.pp monad_type_ctor)
                | Some(Tc_type(td)) -> begin
                    match td.type_tparams with
                     | [Nv _] ->
                         raise (Reporting_basic.err_type_pp mod_id.id_locn "monad type constructor with a number parameter" 
                          Path.pp monad_type_ctor)
                     | [Ty _] -> ()
                     | tnvars ->
                          raise (Reporting_basic.err_type_pp mod_id.id_locn 
                            (Printf.sprintf "monad type constructor with %d parameters" 
                              (List.length tnvars))
                            Path.pp monad_type_ctor)
                  end
            in
            let (return_tvs, return_type) = 
              check_const_for_do mod_id T.e.c_env mod_env.v_env "return" in
            let build_monad_type tv = {t = Tapp([{t = Tvar(tv)}], monad_type_ctor)} in
            let () =
              match return_tvs with
                | [tv] ->
                    assert_equal mod_id.id_locn "do/return"
                      T.d return_type 
                      { t = Tfn({t = Tvar(tv)}, build_monad_type tv) }
                | tvs ->
                    raise (Reporting_basic.err_type_pp mod_id.id_locn (Printf.sprintf "monad return function with %d type parameters" (List.length tvs))
                      Path.pp mod_id.descr.mod_binding)
            in
            let (bind_tvs, bind_type) = 
              check_const_for_do mod_id T.e.c_env mod_env.v_env "bind" in
            let build_bind_type tv1 tv2 =
              { t = Tfn(build_monad_type tv1, 
                        { t = Tfn({t = Tfn({ t = Tvar(tv1)}, 
                                           build_monad_type tv2)},
                                  build_monad_type tv2)})}
            in
            let direction =
              match bind_tvs with
                | [tv1;tv2] ->
                    (try
                      assert_equal mod_id.id_locn "do/>>="
                        T.d bind_type
                        (build_bind_type tv1 tv2);
                      1
                    with
                      Reporting_basic.Fatal_error (Reporting_basic.Err_type _) ->
                        assert_equal mod_id.id_locn "do/>>="
                          T.d bind_type
                          (build_bind_type tv2 tv1);
                      2)
                | tvs ->
                    raise (Reporting_basic.err_type_pp mod_id.id_locn (Printf.sprintf "monad >>= function with %d type parameters" (List.length tvs))
                      Path.pp mod_id.descr.mod_binding)
            in
            let (lns_env,lns) = check_lns l_e monad_type_ctor lns in
            let lns = List.rev lns in
            let env = Nfmap.union l_e lns_env in
            let exp = check_exp env e in
            let a = C.new_type () in
              C.equate_types l "do expression" (exp_to_typ exp)
                { t = Tapp([a], monad_type_ctor) };
              C.equate_types l "do expression" (exp_to_typ exp) ret_type;
              A.mk_do l sk1 mod_id lns sk2 exp sk3 (a,direction) rt

  and check_lns (l_e : lex_env) 
                (monad_type_ctor : Path.t)
                (lns : (Ast.pat*Ast.lex_skips*Ast.exp*Ast.lex_skips) list)
                =
    List.fold_left
      (fun (env,lst) -> 
         function
           | (p,s1,e,s2) ->
               let et = check_exp (Nfmap.union l_e env) e in
               let (pt,p_env) = check_pat (Nfmap.union l_e env) p Nfmap.empty in
               let p_env = Nfmap.union env p_env in
               let a = C.new_type () in
                 C.equate_types pt.locn "do expression" pt.typ a;
                 C.equate_types (exp_to_locn et) "do expression" (exp_to_typ et)
                   { t = Tapp([a], monad_type_ctor) };
                 (p_env,
                  Do_line(pt, s1, et, s2)::lst))
      (empty_lex_env,[])
      lns



  (* Corresponds to check_quant_binding or check_listquant_binding
   * 'D,E,EL |- qbind .. qbind gives EL2,S' depending on is_list *)
  and check_qbs (is_list : bool) (l_e : lex_env) (qbs : Ast.qbind list)=
    List.fold_left
      (fun (env,lst) -> 
         function
           | Ast.Qb_var(xl) ->
               if is_list then
                 raise (Reporting_basic.err_type_pp (Ast.xl_to_l xl) "unrestricted quantifier in list comprehension"
                   Name.pp (Name.strip_lskip (Name.from_x xl)));
               let a = C.new_type () in
               let n = Name.from_x xl in
                 (add_binding env (n, Ast.xl_to_l xl) a,
                  Qb_var({ term = n; locn = Ast.xl_to_l xl; typ = a; rest = (); })::lst)
           | Ast.Qb_list_restr(s1,p,s2,e,s3) ->
               let et = check_exp (Nfmap.union l_e env) e in
               let (pt,p_env) = check_pat (Nfmap.union l_e env) p env in
               let a = C.new_type () in
                 C.equate_types pt.locn "quantifier binding" pt.typ a;
                 C.equate_types (exp_to_locn et) "quantifier binding" (exp_to_typ et)
                   { t = Tapp([a], Path.listpath) };
                 (p_env,
                  Qb_restr(true,s1, pt, s2, et, s3)::lst)
           | Ast.Qb_restr(s1,(Ast.Pat_l(_,l) as p),s2,e,s3) ->
               if is_list then
                 raise (Reporting_basic.err_type_pp l "set-restricted quantifier in list comprehension"
                   (* TODO: Add a pretty printer *)
                   (fun _ _ -> ()) p);
               let et = check_exp (Nfmap.union l_e env) e in
               let (pt,p_env) = check_pat (Nfmap.union l_e env) p env in
               let a = C.new_type () in
                 C.equate_types pt.locn "quantifier binding" pt.typ a;
                 C.equate_types (exp_to_locn et) "quantifier binding" (exp_to_typ et) 
                   { t = Tapp([a], Path.setpath) };
                 (p_env,
                  Qb_restr(false,s1, pt, s2, et, s3)::lst))
      (empty_lex_env,[])
      qbs

  and check_fexp (l_e : lex_env) (Ast.Fexp(i,sk1,e,l)) 
                 : (const_descr_ref id * lskips * exp * Ast.l) * t *
                                           const_descr_ref * Ast.l =
    let ((id,t),l') = check_field i in
    let exp = check_exp l_e e in
    let ret_type = C.new_type () in
      C.equate_types l "field expression 3" t { t = Tfn(ret_type, exp_to_typ exp) };
      ((id,sk1,exp,l), ret_type,id.descr, l')

  and check_fexps (l_e : lex_env) (Ast.Fexps(fexps,sk,semi,l)) 
        : (const_descr_ref id * lskips * exp * Ast.l) lskips_seplist * t * const_descr_ref list =
    let fexps = Seplist.from_list_suffix fexps sk semi in
    let stuff = Seplist.map (check_fexp l_e) fexps in
    let ret_type = C.new_type () in
      check_dup_field_names T.e.c_env (Seplist.to_list_map (fun (_,_,n,l) -> (n,l)) stuff);
      Seplist.iter (fun (_,t,_,_) -> C.equate_types l "field expression 4" t ret_type) stuff;
      (Seplist.map (fun (x,_,_,_) -> x) stuff,
       ret_type,
       Seplist.to_list_map (fun (_,_,n,_) -> n) stuff)

  and check_psexp_help l_e ps ot sk e l
        : pat list * (lskips * src_t) option * lskips * exp * t = 
    let ret_type = C.new_type () in
    let (param_pats,pat_env) = check_pats l_e empty_pat_env ps in
    let body_exp = check_exp (Nfmap.union l_e pat_env) e in
    let t = multi_fun (List.map annot_to_typ param_pats) (exp_to_typ body_exp) in
    let annot = 
      match ot with
        | Ast.Typ_annot_none -> 
            None
        | Ast.Typ_annot_some(sk',typ) ->
            let src_t' = typ_to_src_t build_wild C.add_tyvar C.add_nvar T.d T.e.local_env typ in
              C.equate_types l "pattern/expression list" src_t'.typ (exp_to_typ body_exp);
              Some (sk',src_t')
    in
      C.equate_types l "pattern/expression list" ret_type t;
      (param_pats,annot,sk,body_exp,ret_type)

  and check_psexp (l_e : lex_env) (Ast.Patsexp(ps,sk,e,l)) 
        : pat list * lskips * exp * t = 
    let (a,b,c,d,e) = check_psexp_help l_e ps Ast.Typ_annot_none sk e l in
      (a,c,d,e)

  and check_pexp (l_e : lex_env) (Ast.Patexp(p,sk1,e,l)) 
        : (pat * lskips * exp * Ast.l) * t = 
    match check_psexp l_e (Ast.Patsexp([p],sk1,e,l)) with
      | ([pat],_,exp,t) -> ((pat,sk1,exp,l),t)
      | _ -> assert false 

  and check_funcl (l_e : lex_env) (Ast.Funcl(xl,ps,topt,sk,e)) l =
    let (ps,topt,s,e,t) = check_psexp_help l_e ps topt sk e l in
      ({ term = Name.from_x xl;
         locn = Ast.xl_to_l xl;
         typ = t;
         rest = (); },
       (ps,topt,s,e,t))

  and check_letbind_internal (l_e : lex_env) (Ast.Letbind(lb,l)) 
        : letbind * pat_env = 
    match lb with
      | Ast.Let_val(p,topt,sk',e) ->
          let (pat,pat_env) = check_pat l_e p empty_pat_env in
          let exp = check_exp l_e e in
          let annot = 
            match topt with
              | Ast.Typ_annot_none -> 
                  None
              | Ast.Typ_annot_some(sk',typ) ->
                  let src_t' = typ_to_src_t build_wild C.add_tyvar C.add_nvar T.d T.e.local_env typ in
                    C.equate_types l "let expression" src_t'.typ pat.typ;
                    Some (sk',src_t')
          in
            C.equate_types l "let expression" pat.typ (exp_to_typ exp);
            ((Let_val(pat,annot,sk',exp),l), pat_env)
      | Ast.Let_fun(funcl) ->
          let (xl, (a,b,c,d,t)) = check_funcl l_e funcl l in
            ((Let_fun(xl,a,b,c,d),l),
             add_binding empty_pat_env (xl.term, xl.locn) t)

  (* Check lemmata expressions that must have type ret, which is expected to be bool but 
     for flexibility can be provided.
   *)
  let check_lem_exp (l_e : lex_env) l e ret =
    let exp = check_exp l_e e in
    C.equate_types l "top-level expression" ret (exp_to_typ exp);
    let Tconstraints(tnvars,constraints,length_constraints) = C.inst_leftover_uvars l in
    (exp,Tconstraints(tnvars,constraints,length_constraints))

  let check_constraint_subset l cs1 cs2 = 
    unsat_constraint_err l
      (List.filter
         (fun (p,tv) ->
            not (List.exists 
                   (fun (p',tv') -> 
                      Path.compare p p' = 0 && tnvar_compare tv tv' = 0)
                   cs2))
         cs1)

  let check_constraint_redundancies l csl csv =
    List.iter (fun c -> C.check_numeric_constraint_implication l c csv) csl

  (* Check that a value definition has the right type according to previous
   * definitions of that name in the same module.
   * def_targets is None if the definitions is not target specific, otherwise it
   * is the set of targets that the definition is for.  def_env is the name and
   * types of all of the variables defined *)
  let apply_specs_for_def (def_targets : Targetset.t option) (l:Ast.l) 
    (def_env :  (Types.t * Ast.l) Typed_ast.Nfmap.t)  =
    Nfmap.iter
      (fun n (t,l) ->
         let const_data = Nfmap.apply T.new_module_env.v_env n in
           match const_data with
             | None ->
                 (* The constant is not defined yet. Check whether the definition is target
                    specific and raise an exception in this case. *)
                 begin
                   match def_targets with
                     | Some _ -> 
                         raise (Reporting_basic.err_type_pp l
                           "target-specific definition without preceding 'val' specification"
                           Name.pp n)
                     | None -> ()
                 end
             | Some(c) ->
                 (* The constant is defined. Check, whether we are alowed to add another, target specific
                    definition. *)
                 let cd = c_env_lookup l T.e.c_env c in
                 begin
                   match cd.env_tag with
                     | K_let ->
                         (* only let's (and vals) can aquire more targets,
                            check whether only new targets are added *)
                         let duplicate_targets = (match def_targets with
                            | None -> cd.const_targets
                            | Some dt -> Targetset.inter cd.const_targets dt) in
                         let relevant_duplicate_targets = Targetset.inter duplicate_targets T.targets in
                         let _ = if not (Targetset.is_empty relevant_duplicate_targets) then
                             raise (Reporting_basic.err_type_pp l
                               (Printf.sprintf "defined variable already has a %s-specific definition" 
                                  (non_ident_target_to_string 
                                     (Targetset.choose relevant_duplicate_targets)))
                               Name.pp n) in
                         
                         (* enforce that the already defined constant and the new one have the same type. *)
                         let a = C.new_type () in begin
                           C.equate_types cd.spec_l "applying val specification" a cd.const_type;
                           C.equate_types l "applying val specification" a t
                         end
                     | _ -> 
                         (* everything else can't be extended, so raise an exception *)
                         raise (Reporting_basic.err_type_pp l ("defined variable is already defined as a " ^ 
                              (env_tag_to_string cd.env_tag))
                           Name.pp n)
                 end
      ) def_env;
    let Tconstraints(tnvars, constraints,l_constraints) = C.inst_leftover_uvars l in
      Nfmap.iter
        (fun n (_,l') ->
           match Nfmap.apply T.e.local_env.v_env n with
             | None -> ()
             | Some(c) ->
                 let cd = c_env_lookup l T.e.c_env c in (
                 check_constraint_subset l constraints cd.const_class;
                 check_constraint_redundancies l l_constraints cd.const_ranges))
        def_env;
      Tconstraints(tnvars, constraints,l_constraints)

  let apply_specs_for_method def_targets l def_env inst_type =
    Nfmap.iter
      (fun n (t,l) ->
         if not (def_targets = None) then
           raise (Reporting_basic.err_type_pp l "instance method must not be target specific"
             Name.pp n);
         let const_ref = Nfmap.apply T.e.local_env.v_env n in
         let const_data = Util.option_map (fun c -> c_env_lookup l T.e.c_env c) const_ref in
         match const_data with
             | Some(cd) when cd.env_tag = K_method ->
                 (* assert List.length c.const_tparams = 1 *)
                 let tv = List.hd cd.const_tparams in 
                 let subst = TNfmap.from_list [(tv, inst_type)] in
                 let spec_typ = type_subst subst cd.const_type in
                 let a = C.new_type () in
                   C.equate_types cd.spec_l "applying val specification" a spec_typ;
                   C.equate_types l "applying val specification" a t
             | _ -> 
                 raise (Reporting_basic.err_type_pp l "instance method not bound to class method"
                   Name.pp n))
      def_env;
    let Tconstraints(tnvars, constraints,l_constraints) = C.inst_leftover_uvars l in
      unsat_constraint_err l constraints;
      Tconstraints(tnvars, [], l_constraints)

  let apply_specs for_method (def_targets : Targetset.t option) l env = 
    match for_method with
      | None -> apply_specs_for_def def_targets l env
      | Some(t) -> apply_specs_for_method def_targets l env t

  (* See Expr_checker signature above *)
  let check_letbind for_method (def_targets : Targetset.t option) l lb =
    let (lb,pe) = check_letbind_internal empty_lex_env lb in
    (lb, pe, apply_specs for_method def_targets l pe)

  (* See Expr_checker signature above *)
  let check_funs for_method (def_targets : Targetset.t option) l funcls =
    let env =
      List.fold_left
        (fun l_e (Ast.Rec_l(Ast.Funcl(xl,_,_,_,_),_)) ->
           let n = Name.strip_lskip (Name.from_x xl) in
             if Nfmap.in_dom n l_e then
               l_e
             else
               add_binding l_e (xl_to_nl xl) (C.new_type ()))
        empty_lex_env
        (Seplist.to_list funcls)
      in
      let funcls = 
        Seplist.map
          (fun (Ast.Rec_l(funcl,l')) -> 
             let (n,(a,b,c,d,t)) = check_funcl env funcl l' in
               C.equate_types l' "top-level function" t 
                 (match Nfmap.apply env (Name.strip_lskip n.term) with
                    | Some(t,_) -> t
                    | None -> assert false);
               (n,a,b,c,d))
          funcls
      in
        (funcls, env, apply_specs for_method def_targets l env)


  (* See Expr_checker signature above *)
  let check_indrels (ctxt : defn_ctxt) (mod_path : Name.t list) (def_targets : Targetset.t option) l names clauses =
    let rec_env =
      List.fold_left
        (fun l_e (Ast.Name_l (Ast.Inderln_name_Name(_,x_l,_,_,_,_,_,_),_),_) ->
          let n = Name.strip_lskip (Name.from_x x_l) in
              if Nfmap.in_dom n l_e then 
                assert false (* TODO Make this an error of duplicate definitions *)
              else
                add_binding l_e (xl_to_nl x_l) (C.new_type ())) 
         empty_lex_env
         names
    in
    let names = Seplist.from_list names in
    let n = 
      Seplist.map 
         (fun (Ast.Name_l(Ast.Inderln_name_Name(s0,xl,s1,Ast.Ts(cp,typ),witness_opt,check_opt,functions_opt,s2), l1)) ->
            let (src_cp, tyvars, tnvarset, (sem_cp,sem_rp)) = check_constraint_prefix ctxt cp in 
            let () = check_free_tvs tnvarset typ in
            let src_t = typ_to_src_t anon_error ignore ignore ctxt.all_tdefs ctxt.cur_env typ in
            let r_t = src_t.typ in
            (* Todo add checks and processing of witness_opt, check_opt, and funcitons_opt *)
            let witness,wit_path,ctxt  = (match witness_opt with
                            | Ast.Witness_none -> None,None,ctxt
                            | Ast.Witness_some (s0,s1,xl,s2) -> 
                              let n = Name.from_x xl in
                              let tn = Name.strip_lskip n in
                              let type_path = Path.mk_path mod_path tn in
                              let new_ctxt = add_p_to_ctxt ctxt (tn, (type_path, (Ast.xl_to_l xl))) in
                              Some( Indreln_witness(s0,s1,n,s2)), 
                                    Some type_path, 
                                    add_d_to_ctxt new_ctxt type_path (mk_tc_type [] None)) in
            let check = (match check_opt with 
                            | Ast.Check_none -> None
                            | Ast.Check_some(s0,xl,s1) -> Some(s0,Name.from_x xl,s1)) in
            let to_src_t = typ_to_src_t_indreln wit_path ctxt.all_tdefs ctxt.cur_env r_t in
            let rec mk_functions fo =
                match fo with
                  | Ast.Functions_none -> None
                  | Ast.Functions_one(xl,s1,t) -> Some([Indreln_fn(Name.from_x xl,s1,to_src_t t,None)])
                  | Ast.Functions_some(xl,s1,t,s2,fs) -> 
                     (match (mk_functions fs) with
                      | None -> Some([Indreln_fn(Name.from_x xl, s1, to_src_t t, Some s2)])
                      | Some fs -> Some((Indreln_fn(Name.from_x xl,s1, to_src_t t, Some s2))::fs)) in
            RName(s0,Name.from_x xl,nil_const_descr_ref,s1,(src_cp,src_t),witness, check, mk_functions functions_opt,s2))
         names 
    in
    let clauses = Seplist.from_list clauses in
    let c =
      Seplist.map
        (fun (Ast.Rule_l(Ast.Rule(xl,s0,s1,ns,s2,e,s3,xl',es), l2)) ->
           let quant_env =
             List.fold_left
               (fun l_e nt -> match nt with
                              | Ast.Name_t_name xl -> add_binding l_e (xl_to_nl xl) (C.new_type ())
                              | Ast.Name_t_nt (_,xl,_,t,_) -> add_binding l_e (xl_to_nl xl) (C.new_type ()) (*Need to equate this type to t*))
               empty_lex_env
               ns
           in
           let extended_env = Nfmap.union rec_env quant_env in
           let et = check_exp extended_env e in
           let ets = List.map (check_exp extended_env) es in
           let new_name = Name.from_x xl in
           let new_name' = annot_name (Name.from_x xl') (Ast.xl_to_l xl') rec_env in
             C.equate_types l2 "inductive relation" (exp_to_typ et) { t = Tapp([], Path.boolpath) };
             C.equate_types l2 "inductive relation"
               new_name'.typ 
               (multi_fun 
                  (List.map exp_to_typ ets) 
                  { t = Tapp([], Path.boolpath) });
             (Rule(new_name,
              s0,
              s1,
              List.map 
                (fun (Ast.Name_t_name xl) -> QName (annot_name (Name.from_x xl) (Ast.xl_to_l xl) quant_env))
                ns,
              s2,
              Some et,
              s3,
              new_name',
              nil_const_descr_ref,
              ets),l2))
        clauses
    in
      (n,c,rec_env, apply_specs None def_targets l rec_env)

end

let tvs_to_set (tvs : (Types.tnvar * Ast.l) list) : TNset.t =
  match DupTvs.duplicates (List.map fst tvs) with
    | DupTvs.Has_dups(tv) ->
        let (tv',l) = 
          List.find (fun (tv',_) -> TNvar.compare tv tv' = 0) tvs
        in
          raise (Reporting_basic.err_type_pp l "duplicate type variable" TNvar.pp tv')
    | DupTvs.No_dups(tvs_set) ->
        tvs_set

let anon_error l = 
  raise (Reporting_basic.err_type l "anonymous types not permitted here: _")

let rec check_free_tvs (tvs : TNset.t) (Ast.Typ_l(t,l)) : unit =
  match t with
    | Ast.Typ_wild _ ->
        anon_error l
    | Ast.Typ_var(Ast.A_l((t,x),l)) ->
       if TNset.mem (Ty (Tyvar.from_rope x)) tvs then
        ()
       else
        raise (Reporting_basic.err_type_pp l "unbound type variable" 
          Tyvar.pp (Tyvar.from_rope x))
    | Ast.Typ_fn(t1,_,t2) -> 
        check_free_tvs tvs t1; check_free_tvs tvs t2
    | Ast.Typ_tup(ts) -> 
        List.iter (check_free_tvs tvs) (List.map fst ts)
    | Ast.Typ_Nexps(n) -> check_free_ns tvs n
    | Ast.Typ_app(_,ts) -> 
        List.iter (check_free_tvs tvs) ts
    | Ast.Typ_paren(_,t,_) -> 
        check_free_tvs tvs t
and check_free_ns (nvs: TNset.t) (Ast.Length_l(nexp,l)) : unit =
  match nexp with
   | Ast.Nexp_var((_,x)) ->
       if TNset.mem (Nv (Nvar.from_rope x)) nvs then
        ()
       else
        raise (Reporting_basic.err_type_pp l "unbound length variable" Nvar.pp (Nvar.from_rope x))
   | Ast.Nexp_constant _ -> ()
   | Ast.Nexp_sum(n1,_,n2) | Ast.Nexp_times(n1,_,n2) -> check_free_ns nvs n1 ; check_free_ns nvs n2
   | Ast.Nexp_paren(_,n,_) -> check_free_ns nvs n

(* Support for maps from paths to lists of things *)
let insert_pfmap_list (m : 'a list Pfmap.t) (k : Path.t) (v : 'a) 
      : 'a list Pfmap.t =
  match Pfmap.apply m k with
    | None -> Pfmap.insert m (k,[v])
    | Some(l) -> Pfmap.insert m (k,v::l)

(* Add a new instance the the new instances and the global instances *)
let add_instance_to_ctxt (ctxt : defn_ctxt) (p : Path.t) (i : instance) 
      : defn_ctxt =
  { ctxt with all_instances = insert_pfmap_list ctxt.all_instances p i;
              new_instances = insert_pfmap_list ctxt.new_instances p i; }

let add_let_defs_to_ctxt 
      (* The path of the enclosing module *)
      (mod_path : Name.t list)
      (ctxt : defn_ctxt)
      (* The type and length variables that were generalised for this definition *)
      (tnvars : Types.tnvar list) 
      (* The class constraints that the definition's type variables must satisfy *) 
      (constraints : (Path.t * Types.tnvar) list)
      (* The length constraints that the definition's length variables must satisfy *) 
      (lconstraints : Types.range list)
      (env_tag : env_tag) 
      (new_targs_opt : Targetset.t option) 
      (l_env : lex_env) 
      : defn_ctxt =
  let new_targs = Util.option_default all_targets new_targs_opt in
  let (c_env, new_env) =
    Nfmap.fold
      (fun (c_env, new_env) n (t,l) ->
        match Nfmap.apply ctxt.new_defs.v_env n with
          | None ->
              (* not present yet, so insert a new one *)
              let c_d = 
                    { const_binding = Path.mk_path mod_path n;
                      const_tparams = tnvars;
                      const_class = constraints;
                      const_ranges = lconstraints;
                      const_type = t;
                      spec_l = l;
                      env_tag = env_tag;
                      const_targets = new_targs;
		      relation_info = None;
                      target_rep = Targetmap.empty } in
              let (c_env', c) = c_env_save c_env None c_d in
              (c_env', Nfmap.insert new_env (n, c))
          | Some(c) -> 
              (* The definition is already in the context.  Here we just assume
               * it is compatible with the existing definition, having
               * previously checked it. So, we only need to update the set of targets. *) 
              let c_d = c_env_lookup l c_env c in
              let targs = Targetset.union c_d.const_targets new_targs in
              let (c_env', c) = c_env_save c_env (Some c) { c_d with const_targets = targs } in
              (c_env', Nfmap.insert new_env (n, c)))
      (ctxt.ctxt_c_env, Nfmap.empty) l_env
  in
  { ctxt with 
        ctxt_c_env = c_env;
        cur_env = 
          { ctxt.cur_env with v_env = Nfmap.union ctxt.cur_env.v_env new_env };
        new_defs = 
          { ctxt.new_defs with 
                v_env = Nfmap.union ctxt.new_defs.v_env new_env } }

(* Check a type definition and add it to the context.  mod_path is the path to
 * the enclosing module.  Ignores any constructors or fields, just handles the
 * type constructors. *)
let build_type_def_help (mod_path : Name.t list) (context : defn_ctxt) 
      (tvs : Ast.tnvar list) ((type_name,l) : name_l) (regex : name_sect option) (type_abbrev : Ast.typ option) 
      : defn_ctxt = 
  let tvs = List.map (fun tv -> tnvar_to_types_tnvar (ast_tnvar_to_tnvar tv)) tvs in
  let tn = Name.strip_lskip type_name in
  let type_path = Path.mk_path mod_path tn in
  let () =
    match Nfmap.apply context.new_defs.p_env tn with
      | None -> ()
      | Some(p, _) ->
          begin
            match Pfmap.apply context.all_tdefs p with
              | None -> assert false
              | Some(Tc_type _) ->
                  raise (Reporting_basic.err_type_pp l "duplicate type constructor definition"
                    Name.pp tn)
              | Some(Tc_class _) ->
                  raise (Reporting_basic.err_type_pp l "type constructor already defined as a type class" 
                    Name.pp tn)
          end
  in
  let regex = match regex with | Some(Name_restrict(_,_,_,_,r,_)) -> Some r | _ -> None in
  let new_ctxt = add_p_to_ctxt context (tn, (type_path, l))
  in
    begin
      match type_abbrev with
        | Some(typ) ->
            check_free_tvs (tvs_to_set tvs) typ;
            let src_t = 
              typ_to_src_t anon_error ignore ignore context.all_tdefs context.cur_env typ 
            in
              if (regex = None)
                then add_d_to_ctxt new_ctxt type_path 
                        (mk_tc_type_abbrev (List.map fst tvs) src_t.typ)
                else raise (Reporting_basic.err_type_pp l "Type abbreviations may not restrict identifier names" Name.pp tn)
        | None ->
            add_d_to_ctxt new_ctxt type_path 
              (mk_tc_type (List.map fst tvs) regex)
    end

let build_type_name_regexp (name: Ast.name_opt) : (name_sect option) =
  match name with
    | Ast.Name_sect_none -> None
    | Ast.Name_sect_name( sk1,name,sk2,sk3, regex,sk4) -> 
      let (n,l) = xl_to_nl name in
      if ((Name.to_string (Name.strip_lskip n)) = "name")
         then Some(Name_restrict(sk1,(n,l),sk2,sk3,regex,sk4))
      else 
         raise (Reporting_basic.err_type_pp l "Type name restrictions must begin with 'name'" Name.pp (Name.strip_lskip n))

(* Check a type definition and add it to the context.  mod_path is the path to
 * the enclosing module.  Ignores any constructors or fields, just handles the
 * type constructors. *)
let build_type_def (mod_path : Name.t list) (context : defn_ctxt) (td : Ast.td)
      : defn_ctxt = 
  match td with
    | Ast.Td(xl, tvs, regex, _, td) ->
        build_type_def_help mod_path context tvs (xl_to_nl xl) (build_type_name_regexp regex)
          (match td with
             | Ast.Te_abbrev(t) -> Some(t)
             | _ -> None)
    | Ast.Td_opaque(xl,tvs, regex) ->
        build_type_def_help mod_path context tvs (xl_to_nl xl) (build_type_name_regexp regex) None

(* Check a type definition and add it to the context.  mod_path is the path to
 * the enclosing module.  Ignores any constructors or fields, just handles the
 * type constructors. *)
let build_type_defs (mod_path : Name.t list) (ctxt : defn_ctxt) 
      (tds : Ast.td lskips_seplist) : defn_ctxt =
  List.fold_left (build_type_def mod_path) ctxt (Seplist.to_list tds)

let build_record tvs_set (ctxt : defn_ctxt) 
      (recs : (Ast.x_l * lskips * Ast.typ) lskips_seplist) 
      : (name_l * lskips * src_t) lskips_seplist =
  Seplist.map
    (fun (field_name,sk1,typ) ->
       let l' = Ast.xl_to_l field_name in
       let fn = Name.from_x field_name in
       let src_t = 
         typ_to_src_t anon_error ignore ignore ctxt.all_tdefs ctxt.cur_env typ 
       in
         check_free_tvs tvs_set typ;
         ((fn,l'),sk1,src_t))
    recs

let add_record_to_ctxt build_descr (ctxt : defn_ctxt) 
      (recs : (name_l * lskips * src_t) lskips_seplist) 
      : ((name_l * const_descr_ref * lskips * src_t) lskips_seplist * defn_ctxt)  =
   Seplist.map_acc_left
      (fun ((fn,l'),sk1,src_t) ctxt ->
         let fn' = Name.strip_lskip fn in
         let field_descr = build_descr fn' l' src_t.typ in
         let () = 
           match Nfmap.apply ctxt.new_defs.f_env fn' with
             | None -> ()
             | Some _ ->
                 raise (Reporting_basic.err_type_pp l' "duplicate field name definition"
                   Name.pp fn')
         in
         let (c_env', f) = c_env_save ctxt.ctxt_c_env None field_descr in
         let ctxt = {ctxt with ctxt_c_env = c_env'} in
         let ctxt = add_f_to_ctxt ctxt (fn', f)
         in
           ((fn, l'),f,sk1,src_t), ctxt)
      ctxt
      recs

let rec build_variant build_descr tvs_set (ctxt : defn_ctxt) 
      (vars : Ast.ctor_def lskips_seplist) 
      : (name_l * const_descr_ref * lskips * src_t lskips_seplist) lskips_seplist * (const_descr_ref list * defn_ctxt) =
  let (sl, (cl, ctxt)) =
  Seplist.map_acc_left
    (fun (Ast.Cte(ctor_name,sk1,typs)) (cl, ctxt) ->
       let l' = Ast.xl_to_l ctor_name in 
       let src_ts =
         Seplist.map 
           (fun t ->
              typ_to_src_t anon_error ignore ignore ctxt.all_tdefs ctxt.cur_env t) 
           (Seplist.from_list typs)
        in
        let ctn = Name.from_x ctor_name in
        let ctn' = Name.strip_lskip ctn in
        let constr_descr : const_descr = build_descr ctn' l' src_ts in        
        let () = (* check, whether the constructor name is already used *)
          match Nfmap.apply ctxt.new_defs.v_env ctn' with
            | None -> (* not used, so everything OK*) ()
            | Some(c) ->
                begin (* already used, produce the right error message *)
                  let c_d = c_env_lookup l' ctxt.ctxt_c_env c in
                  let err_msg = begin
                    match c_d.env_tag with
                      | K_constr -> "duplicate constructor definition"
                      | _ -> "constructor already defined as a " ^ (env_tag_to_string c_d.env_tag)
                  end in
                  raise (Reporting_basic.err_type_pp l' err_msg Name.pp ctn')
                end
        in
        let (c_env', c) = c_env_save ctxt.ctxt_c_env None constr_descr in
        let ctxt : defn_ctxt = {ctxt with ctxt_c_env = c_env'} in
        let ctxt = add_v_to_ctxt ctxt (ctn', c)
        in
          List.iter (fun (t,_) -> check_free_tvs tvs_set t) typs;
          (((ctn,l'),c,sk1,src_ts), (c :: cl, ctxt)))
    ([], ctxt)
    vars in
  (sl, (List.rev cl, ctxt));;


let build_ctor_def (mod_path : Name.t list) (context : defn_ctxt)
      type_name (tvs : Ast.tnvar list)  (regexp : name_sect option) td
      : (name_l * tnvar list * Path.t * texp * name_sect option) * defn_ctxt= 
  let l = Ast.xl_to_l type_name in
  let tnvs = List.map ast_tnvar_to_tnvar tvs in
  let tvs_set = tvs_to_set (List.map tnvar_to_types_tnvar tnvs) in
  let tn = Name.from_x type_name in
  let type_path = Path.mk_path mod_path (Name.strip_lskip tn) in
  begin
    match td with
      | None -> 
          (((tn,l),tnvs,type_path, Te_opaque, regexp), context)
      | Some(sk3, Ast.Te_abbrev(t)) -> 
          (* Check and throw error if there's a regexp here *)
          (((tn,l), tnvs, type_path,
            Te_abbrev(sk3,
                      typ_to_src_t anon_error ignore ignore context.all_tdefs context.cur_env t), None),
           context)
      | Some(sk3, Ast.Te_record(sk1',ntyps,sk2',semi,sk3')) ->
          let ntyps = Seplist.from_list_suffix ntyps sk2' semi in
          let recs = build_record tvs_set context ntyps in
          let tparams = List.map (fun tnv -> fst (tnvar_to_types_tnvar tnv)) tnvs in
          let tparams_t = List.map tnvar_to_type tparams in
          let (recs', ctxt) =
            add_record_to_ctxt 
              (fun fname l t ->
                 { const_binding = Path.mk_path mod_path fname;
                   const_tparams = tparams;
                   const_class = [];
                   const_ranges = [];
                   const_type = { t = Tfn ({ t = Tapp (tparams_t, type_path) }, t) };
                   spec_l = l;
                   env_tag = K_field;
                   relation_info = None;
                   const_targets = all_targets;
                   target_rep = Targetmap.empty })
              context
              (Seplist.map (fun (x,y,src_t) -> (x,y,src_t)) recs)
          in
          let field_refs = Seplist.to_list_map (fun (_, f, _, _) -> f) recs' in
          let ctxt = {ctxt with all_tdefs = type_defs_update_fields l ctxt.all_tdefs type_path field_refs} in 
            (((tn,l), tnvs, type_path, Te_record(sk3,sk1',recs',sk3'), regexp), ctxt)
      | Some(sk3, Ast.Te_variant(sk_init_bar,bar,ntyps)) ->
          let ntyps = Seplist.from_list_prefix sk_init_bar bar ntyps in
          let tparams = List.map (fun tnv -> fst (tnvar_to_types_tnvar tnv)) tnvs in
          let tparams_t = List.map tnvar_to_type tparams in
          let (vars,(cl, ctxt)) =
            build_variant
              (fun cname l ts ->
                 { const_binding = Path.mk_path mod_path cname;
                   const_tparams = tparams;
                   const_class = [];
                   const_ranges = [];
                   const_type = multi_fun (Seplist.to_list_map (fun t -> annot_to_typ t) ts) { t = Tapp (tparams_t, type_path) };
                   spec_l = l;
                   env_tag = K_constr;
                   relation_info = None;
                   const_targets = all_targets;
                   target_rep = Targetmap.empty})
              tvs_set
              context
              ntyps
          in
          let constr_family = {constr_list = cl; constr_case_fun = None; constr_exhaustive = true} in
          let ctxt = {ctxt with all_tdefs = type_defs_add_constr_family l ctxt.all_tdefs type_path constr_family} in 
            (((tn,l),tnvs, type_path, Te_variant(sk3,vars), regexp), ctxt)
  end;;


(* Builds the constructors and fields for a type definition, and the typed AST
 * *) 
let rec build_ctor_defs (mod_path : Name.t list) (ctxt : defn_ctxt) 
      (tds : Ast.td lskips_seplist) 
      : ((name_l * tnvar list * Path.t * texp * name_sect option) lskips_seplist * defn_ctxt) =
  Seplist.map_acc_left
    (fun td ctxt -> 
       match td with
         | Ast.Td(type_name, tnvs, name_sec, sk3, td) ->
             build_ctor_def mod_path ctxt type_name tnvs (build_type_name_regexp name_sec) (Some (sk3,td))
         | Ast.Td_opaque(type_name, tnvs, name_sec) ->
             build_ctor_def mod_path ctxt type_name tnvs (build_type_name_regexp name_sec) None)
    ctxt
    tds  

(* Check a "val" declaration. The name must not be already defined in the
 * current sequence of definitions (e.g., module body) *)
let check_val_spec l (mod_path : Name.t list) (ctxt : defn_ctxt)
      (Ast.Val_spec(sk1, xl, sk2, Ast.Ts(cp,typ))) =
  let l' = Ast.xl_to_l xl in
  let n = Name.from_x xl in
  let n' = Name.strip_lskip n in
  let (src_cp, tyvars, tnvarset, (sem_cp,sem_rp)) = check_constraint_prefix ctxt cp in 
  let () = check_free_tvs tnvarset typ in
  let src_t = typ_to_src_t anon_error ignore ignore ctxt.all_tdefs ctxt.cur_env typ in
  let () = (* check that the name is really fresh *)
    match Nfmap.apply ctxt.new_defs.v_env n' with
      | None -> ()
      | Some(c) -> (* not fresh, so raise an exception *)
          begin 
            let c_d = c_env_lookup l' ctxt.ctxt_c_env c in
            let err_message = "specified variable already defined as a " ^ (env_tag_to_string c_d.env_tag) in
            raise (Reporting_basic.err_type_pp l' err_message Name.pp n')
          end
  in
  let v_d =
    { const_binding = Path.mk_path mod_path n';
      const_tparams = tyvars;
      const_class = sem_cp;
      const_ranges = sem_rp;
      const_type = src_t.typ;
      spec_l = l;
      env_tag = K_let;
      const_targets = Targetset.empty;
      relation_info = None;
      target_rep = Targetmap.empty }
  in
  let (c_env', v) = c_env_save ctxt.ctxt_c_env None v_d in
  let ctxt = { ctxt with ctxt_c_env = c_env' } in
    (add_v_to_ctxt ctxt (n',v),
     (sk1, (n,l'), v, sk2, (src_cp, src_t)))

(* Check a method definition in a type class.  mod_path is the path to the
 * enclosing module. class_p is the path to the enclosing type class, and tv is
 * its type parameter. *)
let check_class_spec l (mod_path : Name.t list) (ctxt : defn_ctxt)
      (class_p : Path.t) (tv : Types.tnvar) (sk1,xl,sk2,typ) 
      : const_descr_ref * const_descr * defn_ctxt * src_t * _ =
  let l' = Ast.xl_to_l xl in
  let n = Name.from_x xl in
  let n' = Name.strip_lskip n in
  let tnvars = TNset.add tv TNset.empty in
  let () = check_free_tvs tnvars typ in
  let src_t = typ_to_src_t anon_error ignore ignore ctxt.all_tdefs ctxt.cur_env typ in
  let () = 
    match Nfmap.apply ctxt.new_defs.v_env n' with
      | None -> ()
      | Some(c) ->
          begin
            let c_d = c_env_lookup l' ctxt.ctxt_c_env c in
            let err_message = 
              match c_d.env_tag with
                | (K_method | K_instance) -> "duplicate class method definition"
                | _ -> "class method already defined as a " ^ (env_tag_to_string c_d.env_tag)
            in
            raise (Reporting_basic.err_type_pp l' err_message Name.pp n')
          end
  in
  let v_d =
    { const_binding = Path.mk_path mod_path n';
      const_tparams = [tv];
      const_class = [(class_p, tv)];
      const_ranges = [];
      const_type = src_t.typ;
      spec_l = l;
      env_tag = K_method;
      const_targets = all_targets;
      relation_info = None;
      target_rep = Targetmap.empty }
  in
  let (c_env', v) = c_env_save ctxt.ctxt_c_env None v_d in
  let ctxt = { ctxt with ctxt_c_env = c_env' } in
  let ctxt = add_v_to_ctxt ctxt (n',v)
  in
    (v, v_d, ctxt, src_t, (sk1, (n,l'), v, sk2, src_t))

let target_opt_to_set_opt : Ast.targets option -> Targetset.t option = function
  | None -> None
  | Some(Ast.Targets_concrete(_,targs,_)) ->
      Some(List.fold_right
             (fun (t,_) ks -> Targetset.add (ast_target_to_target t) ks)
             targs
             Targetset.empty)
  | Some(Ast.Targets_neg_concrete(_,targs,_)) ->
      Some(List.fold_right
             (fun (t,_) ks -> Targetset.remove (ast_target_to_target t) ks)
             targs
             all_targets)

let check_target_opt : Ast.targets option -> Typed_ast.targets_opt = function
  | None -> None
  | Some(Ast.Targets_concrete(s1,targs,s2)) -> 
      Some(false, s1,Seplist.from_list targs,s2)
  | Some(Ast.Targets_neg_concrete(s1,targs,s2)) -> 
      Some(true, s1,Seplist.from_list targs,s2)

let letbind_to_funcl_aux_dest (ctxt : defn_ctxt) (lb_aux, l) = begin
  let l = Ast.Trans("letbind_to_funcl_aux_dest", Some l) in
  let module C = Exps_in_context(struct let env_opt = None let avoid = None end) in
  let get_const_exp_from_name (nls : name_lskips_annot) : (const_descr_ref * exp) = begin
    let n = Name.strip_lskip nls.term in
    let n_ref =  match Nfmap.apply ctxt.cur_env.v_env n with
      | Some(r) -> r
      | _ -> raise (Reporting_basic.err_unreachable true l "n should have been added just before") in
    let n_d = c_env_lookup l ctxt.ctxt_c_env n_ref in
    let id = { id_path = Id_some (Ident.mk_ident None [] n); id_locn = l; descr = n_ref; instantiation = List.map tnvar_to_type n_d.const_tparams } in
    let e = C.mk_const l id (Some (annot_to_typ nls)) in
    (n_ref, e)
  end in
  let (nls, pL, ty_opt, sk, e) = begin match lb_aux with
    | Let_val (p, ty_opt, sk, e) -> begin
         let nls = match Pattern_syntax.pat_to_ext_name p with 
                  | None -> raise (Reporting_basic.err_type l "unsupported pattern in top-level let definition")
                  | Some nls -> nls in
         (nls, [], ty_opt, sk, e)
      end
    | Let_fun (nls, pL, ty_opt, sk, e) -> (nls, pL, ty_opt, sk, e)
  end in
  let (n_ref, n_exp) = get_const_exp_from_name nls in
  (nls, n_ref, n_exp, pL, ty_opt, sk, e)
end 

let letbind_to_funcl_aux sk0 target_opt ctxt (lb : letbind) : val_def = begin
  let l = Ast.Trans ("letbind_to_funcl_aux", None) in
  let create_fun_def = match lb with
     | (Let_val (p, _, _, _), _) -> Pattern_syntax.is_ext_var_pat p
     | _ -> true
  in
  if create_fun_def then begin
     let (nls, n_ref, n_exp, pL, ty_opt, sk, e) = letbind_to_funcl_aux_dest ctxt lb in
     let sl = Seplist.sing (nls, n_ref, pL, ty_opt, sk, e) in
     Fun_def(sk0, FR_non_rec, target_opt, sl)
  end else begin
    let get_const_from_name_annot (nls : name_lskips_annot) : (Name.t * const_descr_ref) = begin
      let n = Name.strip_lskip nls.term in
      let n_ref =  match Nfmap.apply ctxt.cur_env.v_env n with
        | Some(r) -> r
        | _ -> raise (Reporting_basic.err_unreachable true l "n should have been added just before") in
      (n, n_ref)
    end in
    let (p, ty_opt, sk, e) = match lb with | (Let_val (p, ty_opt, sk, e), _) -> (p, ty_opt, sk, e) | _ -> assert false in
    let pvars = Pattern_syntax.pat_vars_src p in
    let name_map = List.map get_const_from_name_annot pvars in
    Let_def(sk0, target_opt,  (p, name_map, ty_opt, sk, e))
  end

end

let letbinds_to_funcl_aux_rec l ctxt (lbs : (_ Typed_ast.lskips_seplist)) : funcl_aux Typed_ast.lskips_seplist =
  let lbs' = Seplist.map (fun (nls, pL, ty_opt, sk, e) -> letbind_to_funcl_aux_dest ctxt (Let_fun (nls, pL, ty_opt, sk, e), l)) lbs in
  let var_subst = Seplist.fold_left (fun (nls, _, n_exp, _, _, _, _) subst -> Nfmap.insert subst (Name.strip_lskip nls.term, Sub n_exp)) Nfmap.empty lbs' in
  let sub = (TNfmap.empty, var_subst) in
  let module C = Exps_in_context(struct let env_opt = None let avoid = None end) in
  let res = Seplist.map (fun (nls, n_ref, n_exp, pL, ty_opt, sk, e) -> (nls, n_ref, pL, ty_opt, sk, C.exp_subst sub e)) lbs' in
  res

(* check "let" definitions. ts is the set of targets for which all variables must be defined (i.e., the
 * current backends, not the set of targets that this definition if for) *)
let check_val_def (ts : Targetset.t) (mod_path : Name.t list) (l : Ast.l) 
      (ctxt : defn_ctxt) 
      (vd : Ast.val_def) :
        (* The updated environment *)
        defn_ctxt * 
        (* The names of the defined values *) lex_env *
        val_def *
        (* The type and length variables the definion is generalised over, and class constraints on the type variables, and length constraints on the length variables *)
        typ_constraints =
  let module T = struct 
    let d = ctxt.all_tdefs 
    let i = ctxt.all_instances 
    let e = defn_ctxt_get_cur_env ctxt
    let new_module_env = ctxt.new_defs
    let targets = ts
  end 
  in
  let target_opt_ast = match vd with
      | Ast.Let_def(_,target_opt,_) -> target_opt
      | Ast.Let_rec(_,_,target_opt,_) -> target_opt
      | Ast.Let_inline (_,_,target_opt,_) ->  target_opt
  in
  let target_set_opt = target_opt_to_set_opt target_opt_ast in
  let target_opt = check_target_opt target_opt_ast in

  let module Checker = Make_checker(T) in
  match vd with
      | Ast.Let_def(sk,_,lb) ->
          let (lb,e_v,Tconstraints(tnvs,constraints,lconstraints)) = Checker.check_letbind None target_set_opt l lb in 
          let ctxt' = add_let_defs_to_ctxt mod_path ctxt (TNset.elements tnvs) constraints lconstraints K_let target_set_opt e_v in
          let (vd : val_def) = letbind_to_funcl_aux sk target_opt ctxt' lb in
          (ctxt', e_v, vd, Tconstraints(tnvs,constraints,lconstraints))
      | Ast.Let_rec(sk1,sk2,_,funcls) ->
          let funcls = Seplist.from_list funcls in
          let (lbs,e_v,Tconstraints(tnvs,constraints,lconstraints)) = Checker.check_funs None target_set_opt l funcls in 
          let ctxt' = add_let_defs_to_ctxt mod_path ctxt (TNset.elements tnvs) constraints lconstraints K_let target_set_opt e_v in
          let fauxs = letbinds_to_funcl_aux_rec l ctxt' lbs in
            (ctxt', e_v, (Fun_def(sk1,FR_rec sk2,target_opt,fauxs)), Tconstraints(tnvs,constraints,lconstraints))
      | Ast.Let_inline (sk1,sk2,_,lb) -> 
          let (lb,e_v,Tconstraints(tnvs,constraints,lconstraints)) = Checker.check_letbind None target_set_opt l lb in 
          let ctxt' = add_let_defs_to_ctxt mod_path ctxt (TNset.elements tnvs) constraints lconstraints K_let target_set_opt e_v in
          let (nls, n_ref, _, pL, ty_opt, sk3, et) = letbind_to_funcl_aux_dest ctxt' lb in
          let args = match Util.map_all Pattern_syntax.pat_to_ext_name pL with
                       | None -> raise (Reporting_basic.err_type l "non-variable pattern in inline")
                       | Some a -> a in         
          let new_tr = CR_inline (l, args, et) in
          let d = c_env_lookup l ctxt'.ctxt_c_env n_ref in
          let ts = Util.option_default Target.all_targets target_set_opt in
          let tr = Targetset.fold (fun t r -> Targetmap.insert r (t,new_tr)) ts d.target_rep in
          let ctxt'' = {ctxt' with ctxt_c_env = c_env_update ctxt'.ctxt_c_env n_ref {d with target_rep = tr}} in
            (ctxt'', e_v, Let_inline(sk1,sk2,target_opt,nls,n_ref,args,sk3,et), Tconstraints(tnvs,constraints,lconstraints))


(* val_defs inside an instance. This call gets compared to [check_val_def] an extra
   type as argument. Functions are looked up in the corresponding class. This class is instantiated
   with the type and then the function is parsed as a function with the intended target type.
   Since instance methods should not refer to each other, in contrast to [check_val_def] the
   ctxt.cur_env is not modified. However, the new definitions are available in ctxt.new_defs. *)
let check_val_def_instance (ts : Targetset.t) (mod_path : Name.t list) (instance_type : Types.t) (l : Ast.l) 
      (ctxt : defn_ctxt) 
      (vd : Ast.val_def) :
        (* The updated environment *)
        defn_ctxt * 
        (* The names of the defined values *) lex_env *
        val_def *
        (* The type and length variables the definion is generalised over, and class constraints on the type variables, and length constraints on the length variables *)
        typ_constraints =

  (* check whether the definition is allowed inside an instance. Only simple, non-target specific let expressions are allowed. *)
  let _ = match vd with
      | Ast.Let_def(_,None,_) -> ()
      | Ast.Let_def(_,Some _,_) -> raise (Reporting_basic.err_type l "instance method must not be target specific");
      | Ast.Let_rec(_,_,_,_) -> raise (Reporting_basic.err_type l "instance method must not be recursive");
      | Ast.Let_inline (_,_,target_opt,_) -> raise (Reporting_basic.err_type l "instance method must not be inlined");
  in

  (* Instantiate the checker. In contrast to check_val_def *)
  let module T = struct 
    let d = ctxt.all_tdefs 
    let i = ctxt.all_instances 
    let e = defn_ctxt_get_cur_env ctxt
    let new_module_env = ctxt.new_defs
    let targets = ts
  end 
  in

  let module Checker = Make_checker(T) in
  match vd with
      | Ast.Let_def(sk,_,lb) ->
          let (lb,e_v,Tconstraints(tnvs,constraints,lconstraints)) = Checker.check_letbind (Some instance_type) None l lb in 

          (* check, whether contraints are satisfied and only simple variable arguments are used (in order to allow simple inlining of
             instance methods. *)
          let _ = unsat_constraint_err l constraints in
          let _ = match lb with
             | (Let_fun (_, pL, _, _, _), _) ->
               if (List.for_all Pattern_syntax.is_ext_var_pat pL) then () else 
                  raise (Reporting_basic.err_type l "instance method must not have non-variable arguments");
             | _ -> () 
          in

          let ctxt' = add_let_defs_to_ctxt mod_path ctxt (TNset.elements tnvs) constraints lconstraints K_instance None e_v in
          let (vd : val_def) = letbind_to_funcl_aux sk None ctxt' lb in

          (* instance methods should not refer to each other. Therefore, remove the bindings added by add_let_defs_to_ctxt from
             ctxt.cur_env. They are still in ctxt.new_defs *)
          let ctxt'' = {ctxt' with cur_env = ctxt.cur_env} in
          (ctxt'', e_v, vd, Tconstraints(tnvs,constraints,lconstraints))

      | _ -> raise (Reporting_basic.err_unreachable true l "if vd is not a simple let, an exception should have already been raised.")


let check_lemma l ts (ctxt : defn_ctxt) 
      : Ast.lemma_decl -> 
        defn_ctxt *
        lskips *
        Ast.lemma_typ * 
        targets_opt *
        (name_l * lskips) option * 
        lskips * exp * lskips =
  let module T = struct 
    let d = ctxt.all_tdefs 
    let i = ctxt.all_instances 
    let e = defn_ctxt_get_cur_env ctxt
    let new_module_env = ctxt.new_defs
    let targets = ts
  end 
  in
  let bool_ty = { Types.t = Types.Tapp ([], Path.boolpath) } in
  let module Checker = Make_checker(T) in
  let lty_get_sk = function
    | Ast.Lemma_theorem sk -> (sk, Ast.Lemma_theorem None)
    | Ast.Lemma_assert sk -> (sk, Ast.Lemma_assert None)
    | Ast.Lemma_lemma sk -> (sk, Ast.Lemma_lemma None) in
  let module C = Constraint(T) in
    function
      | Ast.Lemma_unnamed (lty, target_opt, sk1, e, sk2) ->
          let (exp,constraints) = Checker.check_lem_exp empty_lex_env l e bool_ty in
          let (sk0, lty') = lty_get_sk lty in
          let target_opt = check_target_opt target_opt in
              (ctxt, sk0, lty', target_opt, None, sk1, exp, sk2) 
      | Ast.Lemma_named (lty, target_opt, name, sk1, sk2, e, sk3) ->
          let (exp,Tconstraints(tnvars,constraints,lconstraints)) = Checker.check_lem_exp empty_lex_env l e bool_ty in
          (* TODO It's ok for tnvars to have variables (polymorphic lemma), but typed ast should keep them perhaps? Not sure if it's ok for constraints to be unconstrained or if we need length constraints kept *)
          let target_opt = check_target_opt target_opt in
          let (sk0, lty') = lty_get_sk lty in
          let (n, l) = xl_to_nl name in
          let n_s = Name.strip_lskip n in
          let _ = if (NameSet.mem n_s ctxt.lemmata_labels) then 
                      raise (Reporting_basic.err_type_pp l
                        "lemmata-label already used"
                         Name.pp n_s)
                   else () in
          (add_lemma_to_ctxt ctxt n_s,  sk0, lty', target_opt, Some ((n,l), sk1), sk2, exp, sk3)

(* Check that a type can be an instance.  That is, it can be a type variable, a
 * function between type variables, a tuple of type variables or the application
 * of a (non-abbreviation) type constructor to variables.  Returns the
 * variables, and which kind of type it was. *)
let rec check_instance_type_shape (ctxt : defn_ctxt) (src_t : src_t)
      : TNset.t * Ulib.Text.t =
  let l = src_t.locn in 
  let err () = 
    raise (Reporting_basic.err_type_pp l "class instance type must be a type constructor applied to type variables"
      pp_type src_t.typ)
  in
  let to_tnvar src_t = 
    match src_t.term with
      | Typ_var(_,t) -> (Ty(t),src_t.locn)
      | Typ_len(n) -> (match n.nterm with 
                         | Nexp_var(_,n) -> (Nv(n),src_t.locn) 
                         | _ -> err ())
      | _ -> err ()
  in
  match src_t.term with
    | Typ_wild _ -> err ()
    | Typ_var(_,tv) -> (tvs_to_set [(Ty(tv),src_t.locn)], r"var")
    | Typ_fn(t1,_,t2) ->
        (tvs_to_set [to_tnvar t1; to_tnvar t2], r"fun")
    | Typ_tup(ts) ->
        (tvs_to_set (Seplist.to_list_map to_tnvar ts), r"tup")
    | Typ_app(p,ts) ->
        begin
          match Pfmap.apply ctxt.all_tdefs p.descr with
            | Some(Tc_type {type_abbrev = Some _}) ->
                raise (Reporting_basic.err_type_pp p.id_locn "type abbreviation in class instance type"
                  Ident.pp (match p.id_path with | Id_some id -> id | Id_none _ -> assert false))
            | _ -> 
                (tvs_to_set (List.map to_tnvar ts),
                 Name.to_rope (Path.to_name p.descr))
        end
    | Typ_len(n) ->
        begin
          match n.nterm with
            | Nexp_var(_,n) -> (tvs_to_set [(Nv(n),src_t.locn)], r"nvar")
            | Nexp_const(_,i) -> (tvs_to_set [], r"const")
            | _ -> err ()
        end
    | Typ_paren(_,t,_) -> check_instance_type_shape ctxt t

(* If a definition is target specific, we only want to check it with regards to
 * the backends that we are both translating to, and that it is for *)
let ast_def_to_target_opt = function
    | Ast.Val_def(Ast.Let_def(_,target_opt,_) |
                  Ast.Let_inline(_,_,target_opt,_) |
                  Ast.Let_rec(_,_,target_opt,_)) -> Some target_opt
    | Ast.Indreln(_,target_opt,_,_) -> Some target_opt
    | Ast.Lemma(Ast.Lemma_unnamed(_,target_opt,_,_,_)) -> Some target_opt
    | Ast.Lemma(Ast.Lemma_named(_,target_opt,_,_,_,_,_)) -> Some target_opt
    | Ast.Type_def _ -> None
    | Ast.Ident_rename _ -> None
    | Ast.Module _ -> None
    | Ast.Rename _ -> None
    | Ast.Open _ -> None
    | Ast.Spec_def _ -> None
    | Ast.Class _ -> None
    | Ast.Instance _ -> None


let change_effective_backends (backend_targets : Targetset.t) (Ast.Def_l(def,l)) = 
  match (ast_def_to_target_opt def) with 
    | None -> None
    | Some target_opt ->
        begin
          match target_opt_to_set_opt target_opt with
            | None -> None
            | Some(ts) -> 
                Some(Targetset.inter ts backend_targets)
        end

(* backend_targets is the set of targets for which all variables must be defined
 * (i.e., the current backends, not the set of targets that this definition if
 * for) *)
let rec check_def (backend_targets : Targetset.t) (mod_path : Name.t list) 
      (ctxt : defn_ctxt) (Ast.Def_l(def,l)) semi_sk semi 
      : defn_ctxt * def_aux =
  let module T = 
    struct 
      let d = ctxt.all_tdefs 
      let i = ctxt.all_instances 
      let e = defn_ctxt_get_cur_env ctxt
      let new_module_env = ctxt.new_defs
    end 
  in
    match def with
      | Ast.Type_def(sk,tdefs) ->
          let tdefs = Seplist.from_list tdefs in
          let new_ctxt = build_type_defs mod_path ctxt tdefs in
          let (res,new_ctxt) = build_ctor_defs mod_path new_ctxt tdefs in
            (new_ctxt,Type_def(sk,res))
      | Ast.Val_def(val_def) ->
          let (ctxt',_,vd,Tconstraints(tnvs,constraints,lconstraints)) = 
            check_val_def backend_targets mod_path l ctxt val_def 
          in
            (ctxt', Val_def(vd,tnvs, constraints))
      | Ast.Lemma(lem) ->
            let (ctxt', sk, lty, targs, name_opt, sk2, e, sk3) = check_lemma l backend_targets ctxt lem in
            (ctxt', Lemma(sk, lty, targs, name_opt, sk2, e, sk3))
      | Ast.Ident_rename(sk1,target_opt,id,sk2,xl') ->        
          let l' = Ast.xl_to_l xl' in
          let n' = Name.from_x xl' in 
          let id' = Ident.from_id id in
          let targs = check_target_opt target_opt in

          (* do the renaming *)
          let (nk, p) = lookup_name (defn_ctxt_get_cur_env ctxt) id in
          let ctxt' = match nk with
            | (Nk_const c | Nk_field c | Nk_constr c) ->
              begin 
                let cd = c_env_lookup l ctxt.ctxt_c_env c in
                let cd' = List.fold_left (fun cd t -> 
                   match constant_descr_rename t (Name.strip_lskip n') l cd with
                     | Some (cd', _) -> cd'
                     | None -> raise (Reporting_basic.Fatal_error (Reporting_basic.Err_internal (l, "could not rename constant. This is a bug and should not happen."))))
                   cd (targets_opt_to_list targs) in
                let c_env' = c_env_update ctxt.ctxt_c_env c cd' in
                {ctxt with ctxt_c_env = c_env'}
              end
            | Nk_typeconstr p -> 
              begin 
                let td' = List.fold_left (fun td t -> type_defs_rename_type l td p t (Name.strip_lskip n'))
                   ctxt.all_tdefs (targets_opt_to_list targs) in
                {ctxt with all_tdefs = td'}
              end
            | Nk_module m -> ctxt
            | Nk_class -> ctxt
          in
             (ctxt',
             (Ident_rename(sk1, targs,
                     p, id', 
                     sk2, (n', l'))))
      | Ast.Module(sk1,xl,sk2,sk3,Ast.Defs(defs),sk4) ->
          let l' = Ast.xl_to_l xl in
          let n = Name.from_x xl in 
          let n' = Name.strip_lskip n in 
          let ctxt1 = { ctxt with new_defs = empty_local_env } in
          let (new_ctxt,ds) = 
            check_defs backend_targets (mod_path @ [Name.strip_lskip n]) ctxt1 defs 
          in
          let ctxt2 = {new_ctxt with new_defs = ctxt.new_defs; cur_env = ctxt.cur_env }
          in
            (add_m_to_ctxt l' ctxt2 (Name.strip_lskip n) { mod_binding = Path.mk_path mod_path n'; mod_env = new_ctxt.new_defs },
             Module(sk1,(n,l'),Path.mk_path mod_path n',sk2,sk3,ds,sk4))
      | Ast.Rename(sk1,xl',sk2,i) ->
          let l' = Ast.xl_to_l xl' in
          let n = Name.from_x xl' in 
          let mod_descr = lookup_mod ctxt.cur_env i in
            (add_m_to_ctxt l' ctxt (Name.strip_lskip n) mod_descr,
             (Rename(sk1,
                     (n,l'), 
                     Path.mk_path mod_path (Name.strip_lskip n),
                     sk2,
                     { id_path = Id_some (Ident.from_id i);
                       id_locn = l;
                       descr = mod_descr;
                       instantiation = []; })))
      | Ast.Open(sk,i) -> 
          let mod_descr = lookup_mod ctxt.cur_env i in
          let env = mod_descr.mod_env in
            ({ ctxt with cur_env = local_env_union ctxt.cur_env env },
             (Open(sk,
                   { id_path = Id_some (Ident.from_id i);
                     id_locn = l;
                     descr = mod_descr;
                     instantiation = []; })))
      | Ast.Indreln(sk, target_opt, names, clauses) ->
          let module T = struct include T let targets = backend_targets end in
          let module Checker = Make_checker(T) in
          let target_opt_checked = check_target_opt target_opt in
          let target_set_opt = target_opt_to_set_opt target_opt in
          let (ns,cls,e_v,Tconstraints(tnvs,constraints,lconstraints)) = 
            Checker.check_indrels ctxt mod_path target_set_opt l names clauses 
          in 
          let module Conv = Convert_relations.Converter(struct let env_opt = None let avoid = None end) in
          let module C = Exps_in_context(struct let env_opt = None let avoid = None end) in
          let newctxt = add_let_defs_to_ctxt mod_path ctxt (TNset.elements tnvs)
            constraints lconstraints
            K_relation target_set_opt e_v in

          let add_const_ns (RName(sk1, rel_name, _, sk2, rel_type, witness_opt, check_opt, indfns_opt, sk3)) = begin
              let n = Name.strip_lskip rel_name in
              let n_ref =  match Nfmap.apply newctxt.cur_env.v_env n with
                 | Some(r) -> r
                 | _ -> raise (Reporting_basic.err_unreachable true l "n should have been added just before") in
             (RName(sk1, rel_name, n_ref, sk2, rel_type, witness_opt, check_opt, indfns_opt, sk3))
          end in 
          let ns' = Seplist.map add_const_ns ns in

          (* build substitution *)
          let sub = begin
            let var_subst = Seplist.fold_left (fun (RName(_,name,r_ref,_,typschm, _,_,_,_)) subst ->
              begin
    	        let name = Name.strip_lskip name in
                let name_d = c_env_lookup l newctxt.ctxt_c_env r_ref in
                let id = { id_path = Id_some (Ident.mk_ident None [] name); 
                           id_locn = l; descr = r_ref; 
                           instantiation = List.map tnvar_to_type name_d.const_tparams } in
                let name_exp = C.mk_const l id (Some (name_d.const_type)) in
                Nfmap.insert subst (name, Sub name_exp)
              end) Nfmap.empty ns' in
            (TNfmap.empty, var_subst) 
          end in

          let add_const_rule (Rule (name_opt, s1, s1b, qnames, s2, e_opt, s3, rname, _, es), l) = begin
              let n = Name.strip_lskip rname.term in
              let n_ref =  match Nfmap.apply newctxt.cur_env.v_env n with
                 | Some(r) -> r
                 | _ -> raise (Reporting_basic.err_unreachable true l "n should have been added just before") in
              let e_opt' = Util.option_map (C.exp_subst sub) e_opt in
             (Rule (name_opt, s1, s1b, qnames, s2, e_opt', s3, rname, n_ref, es), l)
          end in 
          let cls' = Seplist.map add_const_rule cls in
          let newctxt = Conv.gen_witness_type_info l mod_path newctxt ns' cls' in
          let newctxt = Conv.gen_witness_check_info l mod_path newctxt ns' cls' in
          let newctxt = Conv.gen_fns_info l mod_path newctxt ns' cls' in
            (newctxt,
             (Indreln(sk,target_opt_checked,ns',cls')))
      | Ast.Spec_def(val_spec) ->
          let (ctxt,vs) = check_val_spec l mod_path ctxt val_spec in
            (ctxt, Val_spec(vs))
      | Ast.Class(sk1,sk2,xl,tnv,sk4,specs,sk5) ->
          (* extract class_name cn / cn', the free type variable tv, location l' and full class path p *)

          let l' = Ast.xl_to_l xl in
          let tnvar = ast_tnvar_to_tnvar tnv in 
          let (tnvar_types, _) = tnvar_to_types_tnvar tnvar in

          let cn = Name.from_x xl in
          let cn' = Name.strip_lskip cn in
          let p = Path.mk_path mod_path cn' in

          (* check whether the name of the type class is already used. It lives in the same namespace as types. *)
          let () = 
            match Nfmap.apply ctxt.new_defs.p_env cn' with
              | None -> ()
              | Some(p, _) ->
                  begin
                    match Pfmap.apply ctxt.all_tdefs p with
                      | None -> assert false
                      | Some(Tc_class _) ->
                          raise (Reporting_basic.err_type_pp l' "duplicate type class definition" 
                            Name.pp cn')
                      | Some(Tc_type _) ->
                          raise (Reporting_basic.err_type_pp l' "type class already defined as a type constructor" 
                            Name.pp cn')
                  end
          in

          (* typecheck the methods inside the type class declaration *)
          let (ctxt',vspecs,methods) = 
            List.fold_left
              (fun (ctxt,vs,methods) (a,b,c,d,l) ->
                 let (tc,tc_d,ctxt,src_t,v) = check_class_spec l mod_path ctxt p tnvar_types (a,b,c,d)
                 in
                   (ctxt,
                    v::vs,
                    ((Path.get_name tc_d.const_binding, l), src_t)::methods))
              (ctxt,[],[])
              specs
          in

          (* add the class as a type to the local environment *)
          let ctxt' = add_d_to_ctxt ctxt' p 
             (Tc_class(tnvar_types, List.map (fun ((n,l), src_t) -> (n,src_t.typ)) methods)) in
          let ctxt' = add_p_to_ctxt ctxt' (cn', (p, l')) in

          (****************************************************)
          (* Build a record type for the class's dictionaries *)
          (****************************************************)

          let build_field_name n = Name.rename (fun x -> Ulib.Text.(^^^) x (r"_method")) n in
          let dict_type_name = (Name.lskip_rename (fun x -> Ulib.Text.(^^^) x (r"_class")) cn) in
         
          let tparams = [tnvar_types] in
          let tparams_t = List.map tnvar_to_type tparams in
          let type_path = Path.mk_path mod_path (Name.strip_lskip dict_type_name) in

          let ctxt'' = build_type_def_help mod_path ctxt' [tnv] (dict_type_name, l') None None in
          let (recs', ctxt'') =
            add_record_to_ctxt 
              (fun fname l t ->
                 { const_binding = Path.mk_path mod_path fname;
                   const_tparams = tparams;
                   const_class = [];
                   const_ranges = [];
                   const_type = { t = Tfn ({ t = Tapp (tparams_t, type_path) }, t) };
                   spec_l = l;
                   env_tag = K_field;
                   const_targets = all_targets;
                   relation_info = None;
                   target_rep = Targetmap.empty })
              ctxt''
              (Seplist.from_list (List.map 
                                    (fun ((n,l),src_t) -> 
                                       (((Name.add_lskip (build_field_name n),l), None, src_t),None)) 
                                    methods))
          in
          let field_refs = Seplist.to_list_map (fun (_, f, _, _) -> f) recs' in
          let ctxt''' = {ctxt'' with all_tdefs = type_defs_update_fields l ctxt''.all_tdefs type_path field_refs} in 

          (* all done, return the result *)
          (ctxt''',  Class(sk1,sk2,(cn,l'),tnvar,type_path,sk4,List.rev vspecs, sk5))
      | Ast.Instance(sk1,Ast.Is(cs,sk2,id,typ,sk3),vals,sk4) ->
          (* TODO: Check for duplicate instances *)
          let (src_cs, tyvars, tnvarset, (sem_cs,sem_rs)) =
            check_constraint_prefix ctxt cs 
          in
          let () = check_free_tvs tnvarset typ in
          let src_t = 
            typ_to_src_t anon_error ignore ignore ctxt.all_tdefs ctxt.cur_env typ
          in
          let (used_tvs, type_path) = check_instance_type_shape ctxt src_t in
          let unused_tvs = TNset.diff tnvarset used_tvs in
          let _ = 
            if not (TNset.is_empty unused_tvs) then
              raise (Reporting_basic.err_type_pp l "instance type does not use all type variables"
                TNset.pp unused_tvs)
          in
          let (p, tv, methods0) = lookup_class_p ctxt id in
          let methods = (* Instantiate the type of methods *)
            begin
              let subst = TNfmap.insert TNfmap.empty (tv, src_t.typ) in
              List.map (fun (n, ty) -> (n, type_subst subst ty)) methods0
            end
          in

          (* check that there is no instance already *)
          let _ =  match Types.get_matching_instance ctxt.all_tdefs (p, src_t.typ) ctxt.all_instances  with
                     | Some (l_org, _, _, _) -> begin
                        let class_name =  Pp.pp_to_string (fun ppf -> Path.pp ppf p) in
                        let type_name = Types.t_to_string src_t.typ in
                        let loc_org = Reporting_basic.loc_to_string false l_org in
                        let msg = Format.sprintf 
                                    "duplicate instance declaration: class '%s' has already been instantated for type '%s' at\n    %s" 
                                    class_name type_name loc_org in
                        raise (Reporting_basic.err_type l msg)
                     end
                     | None -> ()
          in

          let instance_name = 
            Name.from_rope
              (Ulib.Text.concat (r"_")
                 [r"Instance";
                  Name.to_rope (Path.to_name p);
                  type_path])
          in
          let instance_path = mod_path @ [instance_name] in

          (** Make instances defined in the header of the instance declaration available during checking methods *)
          let tmp_all_inst = 
            List.fold_left 
              (fun instances (p, tv) -> 
                 insert_pfmap_list instances p (CInstance (Ast.Trans ("Internal Instance", Some l), [], [], tnvar_to_type tv, instance_path)))
              ctxt.all_instances
              sem_cs in
          let ctxt_inst0 = { ctxt with new_defs = empty_local_env; all_instances = tmp_all_inst } in

          (* tycheck the inside of the instance declaration *)
          let (v_env_inst,ctxt_inst,vdefs) = 
            List.fold_left
              (fun (v_env_inst,ctxt,vs) (v,l) ->
                 (* use the val-def normal checking. Notice however, that check_val_def gets the argument
                    [Some src_t.typ] here, while it gets [None] in all *)
                 let (ctxt',e_v',vd,Tconstraints(tnvs,constraints,lconstraints)) = 
                   check_val_def_instance backend_targets instance_path (src_t.typ) l ctxt v 
                 in

                 (* make sure there are no extra contraints and no extra free type variables*)
                 let _ = assert (constraints = []) in
                 let _ = assert (lconstraints = []) in
                 let _ = assert (TNset.is_empty tnvs) in

                 (* we used normal typechecking via check_val_def, so no lets adapt the 
                    resulting functions and check that they have the expected type. *)
                 let fix_def_in_ctxt (ctxt,v_env) n (t, l) = begin
                   let n_ref = match Nfmap.apply ctxt.new_defs.v_env n with
                     | Some r -> r
                     | _ -> raise (Reporting_basic.err_unreachable true l "n should have been added by check_val_def_instance, it is in e_v' after all")
                   in
                   let n_d = c_env_lookup l ctxt.ctxt_c_env n_ref in

                   (* check that [n] has the right type / check whether it is in the set of methods*)
                   let is_method = try
  		       let (_, n_class_ty) = List.find (fun (n', _) -> Name.compare n n' = 0) methods in
                       if Types.check_equal ctxt.all_tdefs n_class_ty n_d.const_type then 
                          (* type matches, everything OK *) true
                       else begin
                         let t_should = Types.t_to_string n_class_ty in
                         let t_is = Types.t_to_string  n_d.const_type in
                         let err_message = ("Instance method '" ^ Name.to_string n ^ "' is excepted to have type\n   " ^
                               t_should^"\nbut has type\n   "^t_is) in
                         raise (Reporting_basic.err_type l err_message)
                       end
                     with Not_found -> raise (Reporting_basic.err_type_pp l "unknown class method" Name.pp n)
                   in

                   let v_env' = if is_method then Nfmap.insert v_env (n, n_ref) else v_env in
                   
                   let n_d' = {n_d with const_tparams = tyvars;
                                        const_class = sem_cs;
					const_ranges = sem_rs;
                                        env_tag = K_instance}
                   in
                   let c_env' = c_env_update ctxt.ctxt_c_env n_ref n_d' in
		     ({ctxt with ctxt_c_env = c_env'}, v_env')
                 end in
                 let (ctxt'',v_env_inst') = Nfmap.fold fix_def_in_ctxt (ctxt',v_env_inst) e_v' in
                   (v_env_inst', ctxt'', vd::vs))
              (Nfmap.empty, ctxt_inst0,[])              
              vals
          in
          let _ = (* All methods present? If not, raise an exception. *)
            List.iter (fun (n,_) ->
                 if not (Nfmap.in_dom n v_env_inst) then
                     (raise (Reporting_basic.err_type_pp l "missing class method" Name.pp n))
                 else ()) methods in

          (* move new definitions into special module, since here the old context is thrown away and ctxt.new_defs is used,
             it afterwards becomes irrelevant thet ctxt_inst.new_defs contains more definitions than ctxt. *)
          let ctxt = begin
	     let ctxt_clean_mod = {ctxt_inst with new_defs = ctxt.new_defs; cur_env = ctxt.cur_env; all_instances = ctxt.all_instances } in
             add_m_to_ctxt l ctxt_clean_mod instance_name { mod_binding =  Path.mk_path mod_path instance_name; mod_env = ctxt_inst.new_defs }
          end in

          (* store everything *)
          let sem_info = 
            { inst_env = v_env_inst;
              inst_name = instance_name;
              inst_class = p;
              inst_tyvars = tyvars;
              inst_constraints = sem_cs;
              inst_methods = methods; }
          in
            (add_instance_to_ctxt ctxt p (CInstance (l, tyvars, sem_cs, src_t.typ, instance_path)),
             Instance(sk1,(src_cs,sk2,Ident.from_id id, src_t, sk3), List.rev vdefs, sk4, 
                      sem_info))


and check_defs (backend_targets : Targetset.t) (mod_path : Name.t list)
              (ctxt : defn_ctxt) defs
              : defn_ctxt * def list =
  match defs with
    | [] -> (ctxt, [])
    | (Ast.Def_l(_,l) as d,sk,semi)::ds ->
        let s = if semi then Some(sk) else None in
          match change_effective_backends backend_targets d with
            | None ->
                let (ctxt,d) = 
                  check_def backend_targets mod_path ctxt d sk semi
                in
                let (ctxt,ds) = check_defs backend_targets mod_path ctxt ds in
                  (ctxt, ((d,s),l,ctxt.cur_env)::ds)
            | Some(new_backend_targets) ->
                if Targetset.is_empty new_backend_targets then
                  check_defs backend_targets mod_path ctxt ds
                else
                  let (ctxt,d) = 
                    check_def new_backend_targets mod_path ctxt d sk semi 
                  in
                  let (ctxt,ds) = 
                    check_defs backend_targets mod_path ctxt ds 
                  in
                    (ctxt, ((d,s),l,ctxt.cur_env)::ds)

(* Code to check that identifiers in type checked program conform to regular expressions specified in type definitions *)

let check_id_restrict_e ctxt (e : Typed_ast.exp) : Typed_ast.exp option =
 let module C = Exps_in_context(struct let env_opt = None let avoid = None end) in
  match C.exp_to_term e with
  | Var(n) -> let id = Name.to_string (Name.strip_lskip n) in
              let head_norm_type = Types.head_norm ctxt.all_tdefs (exp_to_typ e) in
              begin
              match head_norm_type.t with
                 | Tapp(_,p) -> (match Pfmap.apply ctxt.all_tdefs p with
                    | None | Some(Tc_class _) -> assert false
                    | Some(Tc_type { type_varname_regexp = None }) -> None
                    | Some(Tc_type { type_varname_regexp = Some(restrict) }) -> 
                       if (Str.string_match (Str.regexp restrict) id 0) 
                         then None
                         else  raise (Reporting_basic.err_type_pp (exp_to_locn e) 
                               ("variables with type " ^ t_to_string (exp_to_typ e) ^ " are restricted to names matching the regular expression " ^ restrict)
                               Name.pp (Name.strip_lskip n)))
                 | _ -> None
              end
  | _ -> None

let check_id_restrict_p ctxt p = match p.term with
  | P_var(n) -> let id = Name.to_string (Name.strip_lskip n) in
              let head_norm_type = Types.head_norm ctxt.all_tdefs p.typ in
              begin
              match head_norm_type.t with
                 | Tapp(_,path) -> (match Pfmap.apply ctxt.all_tdefs path with
                    | None | Some(Tc_class _) -> assert false
                    | Some(Tc_type { type_varname_regexp = None }) -> None
                    | Some(Tc_type { type_varname_regexp = Some(restrict) }) -> 
                       if (Str.string_match (Str.regexp restrict) id 0) 
                         then None
                         else  raise (Reporting_basic.err_type_pp p.locn 
                               ("variables with type " ^t_to_string p.typ ^ " are restricted to names matching the regular expression " ^ restrict)
                               Name.pp (Name.strip_lskip n) ))
                 | _ -> None
              end
  | _ -> None

let rec check_ids env ctxt defs = 
    let module Ctxt = struct let avoid = None let env_opt = None end in
    let module M = Macro_expander.Expander(Ctxt) in
    let emac = (fun env -> (check_id_restrict_e ctxt)) in
    let pmac = (fun env -> fun ppos -> (check_id_restrict_p ctxt)) in
    let defs = M.expand_defs defs
                     (Macro_expander.list_to_mac [(emac env)],
                      (fun ty -> ty),
                      (fun ty -> ty),
                      Macro_expander.list_to_bool_mac []) in
     let _ = M.expand_defs defs
                     (Macro_expander.list_to_mac [],
                      (fun ty -> ty),
                      (fun ty -> ty),
                      Macro_expander.list_to_bool_mac [(pmac env)])
    in ()

(*  List.iter (fun d -> match d with
               | ((Val_def(Let_def(_,_,letbind),tnvs,consts), _),_) -> () (*TODO check in letbind*)
               | ((Val_def(Rec_def(_,_,_,funcdefs),tnvs,consts),_),_) -> () (*TODO check in funcdefs*)
               | ((Module(_,name,_,_,defs,_), _),_) -> check_ids ctxt defs
(*Indreln of lskips * targets_opt * 
               (Name.lskips_t option * lskips * name_lskips_annot list * lskips * exp option * lskips * name_lskips_annot * exp list) lskips_seplist*)
               | ((Indreln(_,_,reltns),_),_) -> () (*TODO check in reltns *)
               | ((Val_spec v,_),_) -> () (* TODO check in v *)
               | ((Class(_,_,_,_,_,spec_list,_),_),_) -> () (*TODO check in spec_list*)
               | _ -> ())
            defs
*)

let check_defs backend_targets mod_path (env : env)
      (Ast.Defs(defs)) =
  let ctxt = { all_tdefs = env.t_env;
               new_tdefs = [];  
               all_instances = env.i_env;
               new_instances = Pfmap.empty;
               cur_env = env.local_env;
               new_defs = empty_local_env;
               lemmata_labels = NameSet.empty;
               ctxt_c_env = env.c_env }
  in
  let (ctxt,b) = check_defs backend_targets mod_path ctxt defs in
  let env' = { (defn_ctxt_get_cur_env ctxt) with local_env = ctxt.new_defs} in
  let _ = List.map (Syntactic_tests.check_decidable_equality_def env') b in
  let _ = List.map Syntactic_tests.check_positivity_condition_def b in
    check_ids env' ctxt b;    
    (env', b)


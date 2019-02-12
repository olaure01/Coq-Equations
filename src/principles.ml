(**********************************************************************)
(* Equations                                                          *)
(* Copyright (c) 2009-2019 Matthieu Sozeau <matthieu.sozeau@inria.fr> *)
(**********************************************************************)
(* This file is distributed under the terms of the                    *)
(* GNU Lesser General Public License Version 2.1                      *)
(**********************************************************************)

(** Principles derived from equation definitions. *)

open Constr
open Names
open Vars
open Equations_common
open Syntax
open Context_map
open Splitting
open Principles_proofs

type statement = EConstr.constr * EConstr.types option
type statements = statement list

type recursive = bool

type node_kind =
  | Regular
  | Refine
  | Where
  | Nested of recursive

let kind_of_prog p =
  match p.Syntax.program_rec with
  | Some (Structural (NestedOn _)) -> Nested true
  | Some (Structural NestedNonRec) -> Nested false
  | _ -> Regular

let regular_or_nested = function
  | Regular | Nested _ -> true
  | _ -> false

let regular_or_nested_rec = function
  | Regular -> true
  | Nested r -> true
  | _ -> false

let nested = function Nested _ -> true | _ -> false

let pi1 (x,_,_) = x
let pi2 (_,y,_) = y
let pi3 (_,_,z) = z

(** Objects to keep information about equations *)

let cache_rew_rule (base, gr) =
  Autorewrite.add_rew_rules base
    [CAst.make (UnivGen.fresh_global_instance (Global.env()) gr, true, None)]

let subst_rew_rule (subst, (base, gr)) =
  let gr' = Globnames.subst_global_reference subst gr in
  (base, gr')

let inRewRules =
  let open Libobject in
  let obj =
    (* We allow discharging rewrite rules *)
    superglobal_object "EQUATIONS_REWRITE_RULE"
      ~cache:(fun (na, obj) -> cache_rew_rule obj)
      ~subst:(Some subst_rew_rule)
      ~discharge:(fun (_, x) -> Some x)
  in
  declare_object @@ obj

let cache_opacity cst =
  Global.set_strategy (ConstKey cst) Conv_oracle.Opaque

let subst_opacity (subst, cst) =
  let gr' = Mod_subst.subst_constant subst cst in
  gr'

let inOpacity =
  let open Libobject in
  let obj =
    (* We allow discharging rewrite rules *)
    superglobal_object "EQUATIONS_OPACITY"
      ~cache:(fun (na, obj) -> cache_opacity obj)
      ~subst:(Some subst_opacity)
      ~discharge:(fun (_, x) -> Some x)
  in
  declare_object @@ obj

let match_arguments sigma l l' =
  let rec aux i =
    if i < Array.length l' then
      if i < Array.length l then
        if EConstr.eq_constr sigma l.(i) l'.(i) then
          i :: aux (succ i)
        else aux (succ i)
      else aux (succ i)
    else [i]
  in aux 0

let filter_arguments f l =
  let rec aux i f l =
    match f, l with
    | n :: f', a :: l' ->
       if i < n then aux (succ i) f l'
       else if i = n then
         a :: aux (succ i) f' l'
       else assert false
    | _, _ -> l
  in aux 0 f l

module CMap = Map.Make(Constr)

let clean_rec_calls sigma (hyps, c) =
  let open Context.Rel.Declaration in
  (* Remove duplicate induction hypotheses under contexts *)
  let under_context, hyps =
    CMap.partition (fun ty n -> Constr.isProd ty || Constr.isLetIn ty) hyps
  in
  let hyps =
    CMap.fold (fun ty n hyps ->
      let ctx, concl = Term.decompose_prod_assum ty in
      let len = List.length ctx in
      if noccur_between 1 len concl then
          if CMap.mem (lift (-len) concl) hyps then hyps
          else CMap.add ty n hyps
        else CMap.add ty n hyps)
      under_context hyps
  in
  (* Sort by occurrence *)
  let elems = List.sort (fun x y -> Int.compare (snd x) (snd y)) (CMap.bindings hyps) in
  let (size, ctx) =
    List.fold_left (fun (n, acc) (ty, _) ->
    (succ n, LocalAssum (Name (Id.of_string "Hind"), EConstr.Vars.lift n (EConstr.of_constr ty)) :: acc))
    (0, []) elems
  in
  (ctx, size, EConstr.Vars.lift size (EConstr.of_constr c))

let head c = fst (Constr.decompose_app c)

let is_applied_to_structarg f is_rec lenargs =
  match is_rec with
  | Some (Guarded ids) -> begin
     try
       let kind =
         CList.find_map (fun (f', k) -> if Id.equal f f' then Some k else None) ids
       in
       match kind with
       | MutualOn (Some (idx,_)) | NestedOn (Some (idx,_)) -> Some (lenargs > idx)
       | MutualOn None | NestedOn None | NestedNonRec -> Some true
     with Not_found -> None
    end
  | _ -> None

let is_user_obl sigma user_obls f =
  match EConstr.kind sigma f with
  | Const (c, u) -> Id.Set.mem (Label.to_id (Constant.label c)) user_obls
  | _ -> false

let cmap_map f c =
  CMap.fold (fun ty n hyps -> CMap.add (f ty) n hyps) c CMap.empty

let cmap_union g h =
  CMap.merge (fun ty n m ->
    match n, m with
    | Some n, Some m -> Some (min n m)
    | Some _, None -> n
    | None, Some _ -> m
    | None, None -> None) g h

let cmap_add ty n h =
  cmap_union (CMap.singleton ty n) h


let subst_telescope cstr ctx =
  let (_, ctx') = List.fold_left
    (fun (k, ctx') decl ->
      (succ k, (Context.Rel.Declaration.map_constr (substnl [cstr] k) decl) :: ctx'))
    (0, []) ctx
  in List.rev ctx'

let substitute_args args ctx =
  let open Context.Rel.Declaration in
  let rec aux ctx args =
    match args, ctx with
    | a :: args, LocalAssum _ :: ctx -> aux (subst_telescope a ctx) args
    | _ :: _, LocalDef (na, b, t) :: ctx -> aux (subst_telescope b ctx) args
    | [], ctx -> List.rev ctx
    | _, [] -> assert false
  in aux (List.rev ctx) args

let drop_last_n n l =
  let l = List.rev l in
  let l = CList.skipn n l in
  List.rev l

let find_rec_call is_rec sigma protos f args =
  let fm (fhead,(f',filter), alias, idx, sign, arity) =
    if Constr.equal (EConstr.Unsafe.to_constr fhead) f then
      let f' = fst (Constr.destConst f) in
      match is_applied_to_structarg (Names.Label.to_id (Names.Constant.label f')) is_rec
              (List.length args) with
      | Some true | None ->
        let signlen = List.length sign in
        let indargs = filter_arguments filter args in
        let sign, args =
          if signlen <= List.length indargs then
            (* Exact or extra application *)
            let indargs, rest = CList.chop signlen indargs in
            let fargs = drop_last_n (List.length rest) args in
            [], (fargs, indargs, rest)
          else
            (* Partial application *)
            let sign = List.map EConstr.Unsafe.to_rel_decl sign in
            let sign = substitute_args indargs sign in
            let signlen = List.length sign in
            let indargs = List.map (lift signlen) indargs @ Context.Rel.to_extended_list mkRel 0 sign in
            let fargs = List.map (lift signlen) args @ Context.Rel.to_extended_list mkRel 0 sign in
            sign, (fargs, indargs, [])
        in
        Some (idx, arity, filter, sign, args)
      | Some false -> None
    else
      match alias with
      | Some (f',argsf) ->
        let f', args' = Termops.decompose_app_vect sigma f' in
        let f' = EConstr.Unsafe.to_constr f' in
        if Constr.equal (head f') f then
          Some (idx, arity, argsf, [], (args, args, []))
        else None
      | None -> None
  in
  try Some (CList.find_map fm protos)
  with Not_found -> None

let filter_arg i filter =
  let rec aux f =
    match f with
    | i' :: _ when i < i' -> true
    | i' :: _ when i = i' -> false
    | i' :: is -> aux is
    | [] -> false
  in aux filter

let abstract_rec_calls sigma user_obls ?(do_subst=true) is_rec len protos c =
  let proto_fs = List.map (fun (_,(f,args), _, _, _, _) -> f) protos in
  let occ = ref 0 in
  let rec aux n env hyps c =
    let open Constr in
    match kind c with
    | Lambda (na,t,b) ->
      let hyps',b' = aux (succ n) ((na,None,t) :: env) CMap.empty b in
      let hyps' = cmap_map (fun ty -> mkProd (na, t, ty)) hyps' in
        cmap_union hyps hyps', c

    (* | Cast (_, _, f) when is_comp f -> aux n f *)

    | LetIn (na,b,t,body) ->
      let hyps',b' = aux n env hyps b in
      let hyps'',body' = aux (succ n) ((na,Some b,t) :: env) CMap.empty body in
        cmap_union hyps' (cmap_map (fun ty -> Constr.mkLetIn (na,b,t,ty)) hyps''), c

    | Prod (na, d, c) when noccurn 1 c  ->
      let hyps',d' = aux n env hyps d in
      let hyps'',c' = aux n env hyps' (subst1 mkProp c) in
        hyps'', mkProd (na, d', lift 1 c')

    | Case (ci, p, c, brs) ->
      let hyps', c' = aux n env hyps c in
      let hyps' = Array.fold_left (fun hyps br -> fst (aux n env hyps br)) hyps' brs in
      let case' = mkCase (ci, p, c', brs) in
        hyps', EConstr.Unsafe.to_constr (EConstr.Vars.substnl proto_fs (succ len) (EConstr.of_constr case'))

    | Proj (p, c) ->
      let hyps', c' = aux n env hyps c in
        hyps', mkProj (p, c')

    | _ ->
      let f', args = decompose_appvect c in
      if not (is_user_obl sigma user_obls (EConstr.of_constr f')) then
        (match find_rec_call is_rec sigma protos f' (Array.to_list args) with
         | Some (i, arity, filter, sign, (fargs', indargs', rest)) ->
           let hyps =
             CArray.fold_left_i
               (fun i hyps arg ->
                  if filter_arg i filter then hyps
                  else let hyps', arg' = aux n env hyps arg in hyps')
               hyps args
           in
           let fargs' = Constr.mkApp (f', Array.of_list fargs') in
           let result = Termops.it_mkLambda_or_LetIn fargs' sign in
           let hyp =
             Term.it_mkProd_or_LetIn
               (Constr.mkApp (mkApp (mkRel (i + 1 + len + n + List.length sign), Array.of_list indargs'),
                              [| Term.applistc (lift (List.length sign) result)
                                   (Context.Rel.to_extended_list mkRel 0 sign) |]))
               sign
           in
           let hyps = cmap_add hyp !occ hyps in
           let () = incr occ in
           hyps, Term.applist (result, rest)
         | None ->
           let hyps =
             Array.fold_left (fun hyps arg -> let hyps', arg' = aux n env hyps arg in
                               hyps')
               hyps args
           in
           hyps, mkApp (f', args))
      else
        let c' =
          if do_subst then (EConstr.Unsafe.to_constr (EConstr.Vars.substnl proto_fs (len + n) (EConstr.of_constr c)))
          else c
        in hyps, c'
  in clean_rec_calls sigma (aux 0 [] CMap.empty (EConstr.Unsafe.to_constr c))

open EConstr

let subst_app sigma f fn c =
  let rec aux n c =
    match kind sigma c with
    | App (f', args) when eq_constr sigma f f' ->
      let args' = Array.map (map_with_binders sigma succ aux n) args in
      fn n f' args'
    | Var _ when eq_constr sigma f c ->
       fn n c [||]
    | _ -> map_with_binders sigma succ aux n c
  in aux 0 c

let subst_comp_proj sigma f proj c =
  subst_app sigma proj (fun n x args ->
    mkApp (f, if Array.length args > 0 then Array.sub args 0 (Array.length args - 1) else args))
    c

(* Substitute occurrences of [proj] by [f] in the splitting. *)
let subst_comp_proj_split sigma f proj s =
  map_split (subst_comp_proj sigma f proj) s

let is_ind_assum sigma ind b =
  let _, concl = decompose_prod_assum sigma b in
  let t, _ = decompose_app sigma concl in
  if isInd sigma t then
    let (ind', _), _ = destInd sigma t in
    MutInd.equal ind' ind
  else false

let clear_ind_assums sigma ind ctx =
  let rec clear_assums c =
    match kind sigma c with
    | Prod (na, b, c) ->
       if is_ind_assum sigma ind b then
         (assert(not (Termops.dependent sigma (mkRel 1) c));
          clear_assums (Vars.subst1 mkProp c))
       else mkProd (na, b, clear_assums c)
    | LetIn (na, b, t, c) ->
        mkLetIn (na, b, t, clear_assums c)
    | _ -> c
  in map_rel_context clear_assums ctx

let type_of_rel t ctx =
  match Constr.kind t with
  | Rel k -> Vars.lift k (get_type (List.nth ctx (pred k)))
  | c -> mkProp

open Vars

let compute_elim_type env evd user_obls is_rec protos k leninds
                      ind_stmts all_stmts sign app elimty =
  let ctx, arity = decompose_prod_assum !evd elimty in
  let lenrealinds =
    List.length (List.filter (fun (_, (_,_,_,_,_,_,_,(kind,_)),_) -> regular_or_nested_rec kind) ind_stmts) in
  let newctx =
    if lenrealinds == 1 then CList.skipn (List.length sign + 2) ctx
    else ctx
  in
  (* Assumes non-dep mutual eliminator of the graph *)
  let newarity =
    if lenrealinds == 1 then
      it_mkProd_or_LetIn (Vars.substl [mkProp; app] arity) sign
    else
      let clean_one a sign fn =
        let ctx, concl = decompose_prod_assum !evd a in
        let newctx = CList.skipn 2 ctx in
        let newconcl = Vars.substl [mkProp; mkApp (fn, extended_rel_vect 0 sign)] concl in
        it_mkProd_or_LetIn newconcl newctx
      in
      let rec aux arity ind_stmts =
        match kind !evd arity, ind_stmts with
        | _, (i, ((fn, _), _, _, sign, ar, _, _, ((Where | Refine), cut)), _) :: stmts ->
           aux arity stmts
        | App (conj, [| arity; rest |]),
          (i, ((fn, _), _, _, sign, ar, _, _, (refine, cut)), _) :: stmts ->
           mkApp (conj, [| clean_one arity sign fn ; aux rest stmts |])
        | _, (i, ((fn, _), _, _, sign, ar, _, _, _), _) :: stmts ->
           aux (clean_one arity sign fn) stmts
        | _, [] -> arity
      in aux arity ind_stmts
  in
  let newctx' = clear_ind_assums !evd k newctx in
  if leninds == 1 then List.length newctx', it_mkProd_or_LetIn newarity newctx' else
  let sort = fresh_logic_sort evd in
  let methods, preds = CList.chop (List.length newctx - leninds) newctx' in
  let ppred, preds = CList.sep_last preds in
  let newpredfn i d (idx, (f', alias, path, sign, arity, pats, args, (refine, cut)), _) =
    if refine != Refine then d else
    let (n, b, t) = to_tuple d in
    let signlen = List.length sign in
    let ctx = of_tuple (Anonymous, None, arity) :: sign in
    let app =
      let argsinfo =
        CList.map_i
          (fun i (c, (arg, _argnolets)) ->
           let idx = signlen - arg + 1 in (* lift 1, over return value *)
           let ty = Vars.lift (idx (* 1 for return value *))
                         (get_type (List.nth sign (pred (pred idx))))
           in
           (idx, ty, lift 1 c, mkRel idx))
          0 args
      in
      let lenargs = List.length argsinfo in
      let transport = get_efresh logic_eq_case evd in
      let transport ty x y eq c cty =
        mkApp (transport,
               [| ty; x;
                  mkLambda (Name (Id.of_string "abs"), ty,
                            Termops.replace_term !evd (Vars.lift 1 x) (mkRel 1) (Vars.lift 1 cty));
                  c; y; eq (* equality *) |])
      in
      let pargs, subst =
        match argsinfo with
        | [] -> List.map (lift (lenargs+1)) pats, []
        | (i, ty, c, rel) :: [] ->
           List.fold_right
           (fun t (pargs, subst) ->
            let _idx = i + 2 * lenargs in
            let rel = lift lenargs rel in
            let tty = lift (lenargs+1) (type_of_rel (to_constr !evd t) sign) in
            if Termops.dependent !evd rel tty then
              let tr =
                if isRel !evd c then lift (lenargs+1) t
                else
                  transport (lift lenargs ty) rel (lift lenargs c)
                            (mkRel 1) (lift (lenargs+1) (t)) tty
              in
              let t' =
                if isRel !evd c then lift (lenargs+3) (t)
                else transport (lift (lenargs+2) ty)
                               (lift 2 rel)
                               (mkRel 2)
                               (mkRel 1) (lift (lenargs+3) (t)) (lift 2 tty)
              in (tr :: pargs, (rel, t') :: subst)
            else (* for equalities + return value *)
              let t' = lift (lenargs+1) (t) in
              let t' = Termops.replace_term !evd (lift (lenargs) c) rel t' in
              (t' :: pargs, subst)) pats ([], [])
        | _ -> assert false
      in
      let result, _ =
        List.fold_left
        (fun (acc, pred) (i, ty, c, rel) ->
         let idx = i + 2 * lenargs in
         if Termops.dependent !evd (mkRel idx) pred then
           let eqty =
             mkEq env evd (lift (lenargs+1) ty) (mkRel 1)
                  (lift (lenargs+1) rel)
           in
           let pred' =
             List.fold_left
               (fun acc (t, tr) -> Termops.replace_term !evd t tr acc)
               (lift 1 (Termops.replace_term !evd (mkRel idx) (mkRel 1) pred))
               subst
           in
           let transportd = get_efresh logic_eq_elim evd in
           let app =
             mkApp (transportd,
                    [| lift lenargs ty; lift lenargs rel;
                       mkLambda (Name (Id.of_string "refine"), lift lenargs ty,
                                 mkLambda (Name (Id.of_string "refine_eq"), eqty, pred'));
                       acc; (lift lenargs c); mkRel 1 (* equality *) |])
           in (app, subst1 c pred)
         else (acc, subst1 c pred))
        (mkRel (succ lenargs), lift (succ (lenargs * 2)) arity)
        argsinfo
      in
      let ppath = (* The preceding P *)
        match path with
        | _ :: path ->
          (let res =
             list_find_map_i (fun i' (_, (_, _, path', _, _, _, _, _), _) ->
                 if eq_path path' path then Some (idx + 1 - i')
                 else None) 1 ind_stmts
           in match res with None -> assert false | Some i -> i)
        | _ -> assert false
      in
      let papp =
        applistc (lift (succ signlen + lenargs) (mkRel ppath))
                 pargs
      in
      let papp = applistc papp [result] in
      let refeqs = List.map (fun (i, ty, c, rel) -> mkEq env evd ty c rel) argsinfo in
      let app c = List.fold_right
                  (fun c acc ->
                   mkProd (Name (Id.of_string "Heq"), c, acc))
                  refeqs c
      in
      let indhyps =
        List.concat
        (List.map (fun (c, _) ->
              let hyps, hypslen, c' =
                abstract_rec_calls !evd user_obls ~do_subst:false
                   is_rec signlen protos (Reductionops.nf_beta env !evd (lift 1 c))
              in
              let lifthyps = lift_rel_contextn (signlen + 2) (- (pred i)) hyps in
                lifthyps) args)
      in
        it_mkLambda_or_LetIn
          (app (it_mkProd_or_clean env !evd (lift (List.length indhyps) papp)
                                   (lift_rel_context lenargs indhyps)))
          ctx
    in
    let ty = it_mkProd_or_LetIn sort ctx in
    of_tuple (n, Some app, ty)
  in
  let newpreds = CList.map2_i newpredfn 1 preds (List.rev (List.tl ind_stmts)) in
  let skipped, methods' = (* Skip the indirection methods due to refinements,
                              as they are trivially provable *)
    let rec aux stmts meths n meths' =
      match stmts, meths with
      | (Refine, _, _, _) :: stmts, decl :: decls ->
         aux stmts (Equations_common.subst_telescope mkProp decls) (succ n) meths'
      | (_, _, _, None) :: stmts, decls -> (* Empty node, no constructor *)
         aux stmts decls n meths'
      | (_, _, _, _) :: stmts, decl :: decls ->
         aux stmts decls n (decl :: meths')
      | [], [] -> n, meths'
      | [], decls -> n, List.rev decls @ meths'
      | (_, _, _, Some _) :: stmts, [] ->
        anomaly Pp.(str"More statemsnts than declarations while computing eliminator")
    in aux all_stmts (List.rev methods) 0 []
  in
  let ctx = methods' @ newpreds @ [ppred] in
  let elimty = it_mkProd_or_LetIn (lift (-skipped) newarity) ctx in
  let undefpreds = List.length (List.filter (fun decl -> Option.is_empty (get_value decl)) newpreds) in
  let nargs = List.length methods' + undefpreds + 1 in
  nargs, elimty

let replace_vars_context inst ctx =
  List.fold_right
    (fun decl (k, acc) ->
      let decl' = map_rel_declaration (substn_vars k inst) decl in
      (succ k, decl' :: acc))
    ctx (1, [])

let pr_where env sigma ctx ({where_type} as w) =
  let open Pp in
  let envc = Environ.push_rel_context ctx env in
  Printer.pr_econstr_env envc sigma (where_term w) ++ fnl () ++
    str"where " ++ Names.Id.print (where_id w) ++ str" : " ++
    Printer.pr_econstr_env envc sigma where_type ++
    str" := " ++ fnl () ++
    Context_map.pr_context_map env sigma w.where_program.program_prob ++ fnl () ++
    pr_splitting env sigma w.where_program.program_splitting

let where_instance w =
  List.map (fun w -> where_term w) w

let arguments sigma c = snd (Termops.decompose_app_vect sigma c)

let unfold_constr sigma c =
  to82 (Tactics.unfold_in_concl [(Locus.OnlyOccurrences [1], EvalConstRef (fst (destConst sigma c)))])

let extend_prob_ctx delta (ctx, pats, ctx') =
  (delta @ ctx, Context_map.lift_pats (List.length delta) pats, ctx')

let map_proto evd recarg f ty =
  match recarg with
  | Some recarg ->
     let lctx, ty' = decompose_prod_assum evd ty in
     let app =
       let args = Termops.rel_list 0 (List.length lctx) in
       let before, after =
         if recarg == -1 then CList.drop_last args, []
         else let bf, after = CList.chop (pred recarg) args in
              bf, List.tl after
       in
       applistc (lift (List.length lctx) f) (before @ after)
     in
     it_mkLambda_or_LetIn app lctx
  | None -> f

type rec_subst = (Names.Id.t * (int option * EConstr.constr)) list

let cut_problem evd s ctx =
  (* From Γ, x := t, D |- id_subst (G, x, D) : G, x : _, D
     to oΓ, D[t] |- id_subst (G, D) | G[
     ps, prec, ps' : Δ, rec, Δ',
     and s : prec -> Γ |- t : rec
     build
     Γ |- ps, ps' : Δ, Δ'[prec/rec] *)
  let rec fn s (ctxl, pats, ctxr as ctxm) =
    match s with
    | [] -> ctxm
    | (id, (recarg, term)) :: s ->
      try
        let rel, _, ty = Termops.lookup_rel_id id ctxr in
        let fK = map_proto evd recarg term (lift rel ty) in
        let ctxr' = subst_in_ctx rel fK ctxr in
        let left, right = CList.chop (pred rel) pats in
        let right' = List.tl right in
        let s' = List.map (fun (id, (recarg, t)) -> id, (recarg, substnl [fK] rel t)) s in
        fn s' (ctxl, List.append left right', ctxr')
      with Not_found -> fn s ctxm
  in fn s (id_subst ctx)

let subst_rec env evd cutprob s (ctx, p, _ as lhs) =
  let subst =
    List.fold_left (fun (ctx, pats, ctx' as lhs') (id, (recarg, b)) ->
    try let rel, _, ty = Termops.lookup_rel_id id ctx in
        let fK = map_proto evd recarg (mapping_constr evd lhs b) (lift rel ty) in
        let substf = single_subst env evd rel (PInac fK) ctx
        (* ctx[n := f] |- _ : ctx *) in
        compose_subst env ~sigma:evd substf lhs'
    with Not_found (* lookup *) -> lhs') (id_subst ctx) s
  in
  let csubst =
    compose_subst env ~sigma:evd
    (compose_subst env ~sigma:evd subst lhs) cutprob
  in subst, csubst

let map_fix_subst evd ctxmap s =
  List.map (fun (id, (recarg, f)) -> (id, (recarg, mapping_constr evd ctxmap f))) s

(* Not necessary? If p.id is part of the substitution but isn't in the context we ignore it *)
let _program_fixdecls p fixdecls =
  match p.Syntax.program_rec with
  | Some (Structural NestedNonRec) -> (* Actually the definition is not self-recursive *)
     List.filter (fun decl ->
         let na = Context.Rel.Declaration.get_name decl in
         let id = Nameops.Name.get_id na in
         not (Id.equal id p.program_id)) fixdecls
  | _ -> fixdecls

let push_mapping_context env sigma decl ((g,p,d), cut) =
  let open Context.Rel.Declaration in
  let decl' = map_rel_declaration (mapping_constr sigma cut) decl in
  let declassum = LocalAssum (get_name decl, get_type decl) in
  (decl :: g, (PRel 1 :: List.map (lift_pat 1) p), decl' :: d),
  lift_subst env sigma cut [declassum]

(** Assumes the declaration already live in \Gamma to produce \Gamma, decls |- ps : \Delta, decls *)
let push_decls_map env evd (ctx : context_map) cut (g : rel_context) =
  let map, _ = List.fold_right (fun decl acc -> push_mapping_context env evd decl acc) g (ctx, cut) in
  check_ctx_map env evd map

let prsubst env evd s = Pp.(prlist_with_sep spc (fun (id, (recarg, f)) ->
    str (Id.to_string id) ++ str" -> " ++ Printer.pr_econstr_env env !evd f) s)

let subst_rec_programs env evd ps =
  let where_map = ref PathMap.empty in
  let evd = ref evd in
  let cut_problem s ctx' = cut_problem !evd s ctx' in
  let subst_rec cutprob s lhs = subst_rec env !evd cutprob s lhs in
  let rec subst_programs path s ctxlen progs oterms =
    let fixsubst =
      let fn p oterm =
        match p.program_info.program_rec with
        | Some r ->
          let recarg = match r with Structural _ -> None | WellFounded _ -> Some (-1) in
          let oterm = lift (List.length (pi1 p.program_prob) - ctxlen) oterm in
          Some (p.program_info.program_id, (recarg, oterm))
        | None -> None
      in
      let fixdecls = List.map2 fn progs oterms in
      List.rev fixdecls
    in
    let fixsubst = CList.map_filter (fun x -> x) fixsubst in
    (* The previous prototypes must be lifted w.r.t. the new variables bound in the where. *)
    let lifts = List.map (fun (id, (recarg, b)) ->
        (id, (recarg, lift (List.length fixsubst) b))) s in
    let s' = fixsubst @ lifts in
    (* Feedback.msg_debug Pp.(str"In subst_programs, pr_substs" ++ prsubst env evd s'); *)
    let one_program p oterm =
      let split' = match p.program_splitting with
        | RecValid (lets, id, _, s) -> s
        | s -> s
      in
      let rec_prob, rec_arity =
        match p.program_rec with
        | Some { rec_prob; rec_arity } -> rec_prob, rec_arity
        | None -> p.program_prob, p.program_info.program_arity
      in
      let prog_info = p.program_info in
      let cutprob_sign = cut_problem s prog_info.program_sign in
      (* Feedback.msg_debug Pp.(str"In subst_programs: " ++ pr_context env !evd prog_info.program_sign);
       * Feedback.msg_debug Pp.(str"In subst_programs: cutprob_sign " ++ pr_context_map env !evd cutprob_sign); *)
      let cutprob_subst, _ = subst_rec cutprob_sign s (id_subst prog_info.program_sign) in
      (* Feedback.msg_debug Pp.(str"In subst_programs: subst_rec failed " ++ pr_context env !evd prog_info.program_sign); *)
      let program_info' =
        { prog_info with
          program_rec = None;
          program_sign = pi1 cutprob_subst;
          program_arity = mapping_constr !evd cutprob_subst prog_info.program_arity }
      in
      let program' = { p with program_info = program_info' } in
      let path' = p.program_info.program_id :: path in
      (* Feedback.msg_debug Pp.(str"In subst_programs, cut_problem s'" ++ pr_context env !evd (pi1 rec_prob)); *)
      let rec_cutprob = cut_problem s' (pi1 rec_prob) in
      let splitting' = aux rec_cutprob s' program' oterm path' split' in
      let term', ty' = term_of_tree env evd splitting' in
      { program_rec = None;
        program_info = program_info';
        program_prob = id_subst (pi3 cutprob_sign);
        program_term = term';
        program_splitting = splitting' }
    in List.map2 one_program progs oterms

  and aux cutprob s p f path = function
    | Compute ((ctx,pats,del as lhs), where, ty, c) ->
      let subst, lhs' = subst_rec cutprob s lhs in
      let lhss = map_fix_subst !evd lhs s in
      let progctx = (extend_prob_ctx (where_context where) lhs) in
      let substprog, _ = subst_rec cutprob s progctx in
      let islogical = List.exists (fun (id, (recarg, f)) -> Option.has_some recarg) s in
      let subst_where ({where_program; where_path; where_orig;
                        where_program_args;
                        where_type} as w) (subst_wheres, wheres) =
        (* subst_wheres lives in lhs', i.e. has prototypes substituted already *)
        let wcontext = where_context subst_wheres in
        let cutprob' = cut_problem s (pi3 subst) in
        (* Feedback.msg_debug Pp.(str"where_context in subst rec : " ++ pr_context env !evd wcontext);
         * Feedback.msg_debug Pp.(str"lifting subst : " ++ pr_context_map env !evd subst);
         * Feedback.msg_debug Pp.(str"cutprob : " ++ pr_context_map env !evd cutprob'); *)
        let wsubst0 = push_decls_map env !evd subst cutprob' wcontext in
        (* Feedback.msg_debug Pp.(str"new substitution in subst rec : " ++ pr_context_map env !evd wsubst0); *)
        let ctxlen = List.length wcontext + List.length ctx in
        let wp = where_program in
        let where_type = mapping_constr !evd wsubst0 where_type in
        (* The substituted prototypes must be lifted w.r.t. the new variables bound in this where and
           preceding ones. *)
        let s = List.map (fun (id, (recarg, b)) ->
            (id, (recarg, lift ((* List.length subst_wheres + *)
                                List.length (pi1 wp.program_prob) - List.length ctx) b))) lhss in
        let wp' =
          match subst_programs path s ctxlen [wp] [where_term w] with
          | [wp'] -> wp'
          | _ -> assert false
        in
        let wp', args' =
          if islogical || (match wp.program_rec with Some { rec_node = WfRec _ } -> true | _ -> false) then
            let id = Nameops.add_suffix (path_id where_path) "_unfold_eq" in
            let id = Namegen.next_global_ident_away id Id.Set.empty in
            let where_program_term = mapping_constr !evd wsubst0 wp.program_term in
            let where_program_args = List.map (mapping_constr !evd wsubst0) where_program_args in
            where_map := PathMap.add where_path
                (applistc where_program_term where_program_args (* substituted *), id, wp'.program_splitting)
                !where_map;
            let where_program_args = extended_rel_list 0 (pi1 lhs') in
            wp', where_program_args
          else
            let where_program_term = mapping_constr !evd wsubst0 wp.program_term in
            let where_program_args = List.map (mapping_constr !evd wsubst0) where_program_args in
            (* where_map := PathMap.add where_path
             *     (applistc where_program_term where_program_args (\* substituted *\), Id.of_string ""(\*FIXNE*\), wp'.program_splitting)
             *     !where_map; *)
            (* let where_program_args = extended_rel_list 0 (pi1 lhs') in *)
            { wp' with program_term = where_program_term }, where_program_args
        in
        let subst_where =
          {where_program = wp';
           where_program_orig = wp.program_info;
           where_program_args = args';
           where_path;
           where_orig;
           where_context_length = List.length (pi1 lhs');
           where_type }
        in (subst_where :: subst_wheres, w :: wheres)
      in
      let where', _ = List.fold_right subst_where where ([], []) in
      let c' = mapping_rhs !evd substprog c in
      let c' = map_rhs (Reductionops.nf_beta env !evd) (fun i -> i) c' in
      Compute (lhs', where', mapping_constr !evd substprog ty, c')

    | Split (lhs, n, ty, cs) ->
       let subst, lhs' = subst_rec cutprob s lhs in
       let n' = destRel !evd (mapping_constr !evd subst (mkRel n)) in
       Split (lhs', n', mapping_constr !evd subst ty,
              Array.map (Option.map (aux cutprob s p f path)) cs)

    | Mapping (lhs, c) ->
       let subst, lhs' = subst_rec cutprob s lhs in
       Mapping (lhs', aux cutprob s p f path c)

    | RecValid (lhs, id, r, rest) ->
      (match p.program_info.program_rec with
       | Some (WellFounded (_, _, r')) ->
         let recarg = Some (-1) in
         let newprob = r.rec_prob in
         let s = (id, (recarg, lift 1 f)) :: s in
         let cutprob = (cut_problem s (pi1 newprob)) in
         let rest = aux cutprob s p f (id :: path) rest in
         rest
       | _ -> aux cutprob s p f path rest)

    | Refined (lhs, info, sp) ->
       let (id, c, cty), ty, arg, oterm, args, revctx, newprob, newty =
         info.refined_obj, info.refined_rettyp,
         info.refined_arg, info.refined_term, info.refined_args,
         info.refined_revctx, info.refined_newprob, info.refined_newty
       in
       (* Feedback.msg_debug Pp.(str"Before map to newprob " ++ prsubst s); *)
       let lhss = map_fix_subst !evd lhs s in
       (* Feedback.msg_debug Pp.(str"lhs subst " ++ prsubst lhss); *)
       let newprobs = map_fix_subst !evd info.refined_newprob_to_lhs lhss in
       (* Feedback.msg_debug Pp.(str"newprob subst: " ++ prsubst newprobs);
        * Feedback.msg_debug Pp.(str"Newprob to lhs: " ++ pr_context_map env !evd info.refined_newprob_to_lhs);
        * Feedback.msg_debug Pp.(str"Newprob : " ++ pr_context_map env !evd newprob); *)
       let subst, lhs' = subst_rec cutprob s lhs in
       let _, revctx' = subst_rec (cut_problem s (pi3 revctx)) lhss revctx in
       let cutnewprob = cut_problem newprobs (pi3 newprob) in
       let subst', newprob' = subst_rec cutnewprob newprobs newprob in
       let _, newprob_to_prob' =
         subst_rec (cut_problem lhss (pi3 info.refined_newprob_to_lhs)) lhss info.refined_newprob_to_lhs in
       let islogical = List.exists (fun (id, (recarg, f)) -> Option.has_some recarg) s in
       let path' = info.refined_path in
       let s' = aux cutnewprob newprobs p f path' sp in
       let term', args', arg' =
         if islogical then
           let refarg = ref (0,0) in
           let count_lets len =
             let open Context.Rel.Declaration in
             let ctx' = pi1 newprob' in
             let rec aux ctx len =
               if len = 0 then 0
               else
                 match ctx with
                 | LocalAssum _ :: ctx -> succ (aux ctx (pred len))
                 | LocalDef _ :: ctx -> succ (aux ctx len)
                 | [] -> 0
             in aux (List.rev ctx') len
           in
           let args' =
             CList.fold_left_i
               (fun i acc c ->
                 if i == snd arg then
                   (let len = List.length acc in
                    refarg := (count_lets len, len));
                 if isRel !evd c then
                   let d = List.nth (pi1 lhs) (pred (destRel !evd c)) in
                   if List.mem_assoc (Nameops.Name.get_id (get_name d)) s then acc
                   else (mapping_constr !evd subst c) :: acc
                 else (mapping_constr !evd subst c) :: acc) 0 [] args
           in
           let term', _ = term_of_tree env evd s' in
           term', List.rev (List.map (Reductionops.nf_beta env !evd) args'), !refarg
         else
           let first, last = CList.chop (List.length s) (List.map (mapping_constr !evd subst) args) in
           let term' = mapping_constr !evd subst oterm in
           let refarg = (fst arg - List.length s, snd arg - List.length s) in
           (applistc term' first), last, refarg
           (* FIXME , needs substituted position too *)
       in
       let c' = Reductionops.nf_beta env !evd (mapping_constr !evd subst c) in
       let info =
         { refined_obj = (id, c', mapping_constr !evd subst cty);
           refined_rettyp = mapping_constr !evd subst ty;
           refined_arg = arg';
           refined_path = path';
           refined_term = term';
           refined_args = args';
           refined_revctx = revctx';
           refined_newprob = newprob';
           refined_newprob_to_lhs = newprob_to_prob';
           refined_newty = mapping_constr !evd subst' newty }
       in Refined (lhs', info, s')
  in
  let programs' = subst_programs [] [] 0 ps (List.map (fun p -> p.program_term) ps) in
  !where_map, programs'

let unfold_programs env evd flags rec_info progs =
  let where_map, progs' = subst_rec_programs env !evd (List.map fst progs) in
  if PathMap.is_empty where_map && (match rec_info with Some (Logical _) -> false | _ -> true) then
    let one_program (p, prog) p' =
      let norecprob = Context_map.id_subst (program_sign p) in
      let eqninfo =
        Principles_proofs.{ equations_id = p.program_info.program_id;
                            equations_where_map = where_map;
                            equations_f = p.program_term;
                            equations_prob = norecprob }
      in
      let p = { p with program_splitting = p'.program_splitting } in
      p, None, prog, eqninfo
    in List.map2 one_program progs progs'
  else
    let one_program (p, prog) unfoldp =
      let pi = p.program_info in
      let i = pi.program_id in
      let sign = pi.program_sign in
      let arity = pi.program_arity in
      let prob = Context_map.id_subst sign in
      (* let () = Feedback.msg_debug (str"defining unfolding" ++ spc () ++ pr_splitting env split) in *)
      (* We first define the unfolding and show the fixpoint equation. *)
      let unfoldi = Nameops.add_suffix i "_unfold" in
      let unfpi =
        { pi with program_id = unfoldi;
                  program_sign = sign;
                  program_arity = arity }
      in
      let unfoldp = make_single_program env evd flags unfpi prob unfoldp.program_splitting None in
      let unfoldp, term_info = define_program_immediate env evd None [] flags ~unfold:true unfoldp in
      let eqninfo =
        Principles_proofs.{ equations_id = i;
                            equations_where_map = where_map;
                            equations_f = unfoldp.program_term;
                            equations_prob = prob }
      in
      let cst, _ = destConst !evd unfoldp.program_term in
      let cpi' = { program_cst = cst;
                   program_split_info = term_info } in
      p, Some (unfoldp, cpi'), prog, eqninfo
    in
    List.map2 one_program progs progs'

let subst_app sigma f fn c =
  let rec aux n c =
    match kind sigma c with
    | App (f', args) when eq_constr sigma f f' ->
      let args' = Array.map (map_with_binders sigma succ aux n) args in
      fn n f' args'
    | Var _ when eq_constr sigma f c ->
       fn n c [||]
    | _ -> map_with_binders sigma succ aux n c
  in aux 0 c

let substitute_alias evd ((f, fargs), term) c =
  subst_app evd f (fun n f args ->
      if n = 0 then
        let args' = filter_arguments fargs (Array.to_list args) in
        applist (term, args')
      else mkApp (f, args)) c

let substitute_aliases evd fsubst c =
  List.fold_right (substitute_alias evd) fsubst c

type alias = ((EConstr.t * int list) * Names.Id.t * Splitting.splitting)

let make_alias (f, id, s) = ((f, []), id, s)

let smash_rel_context sigma ctx =
  let open Context.Rel.Declaration in
  List.fold_right
    (fun decl (subst, pats, ctx') ->
       match get_value decl with
       | Some b ->
         let b' = substl subst b in
         (b' :: subst, List.map (lift_pat 1) pats, ctx')
       | None -> (mkRel 1 :: List.map (lift 1) subst,
                  PRel 1 :: List.map (lift_pat 1) pats,
                  map_constr (Vars.substl subst) decl :: ctx'))
    ctx ([], [], [])

let _remove_let_pats sigma subst patsubst pats =
  let remove_let pat pats =
    match pat with
    | PRel n ->
      let pat = List.nth patsubst (pred n) in
      (match pat with
       | PInac _ -> pats
       | p -> p :: pats)
    | _ -> specialize sigma patsubst pat :: pats
  in
  List.fold_right remove_let pats []

let smash_ctx_map env sigma (l, p, r as m) =
  let subst, patsubst, r' = smash_rel_context sigma r in
  let smashr' = (r, patsubst, r') in
  compose_subst env ~sigma m smashr', subst

let pattern_instance ctxmap =
  List.rev_map pat_constr (filter_def_pats ctxmap)

let computations env evd alias refine p eqninfo =
  let { equations_prob = prob;
        equations_where_map = wheremap;
        equations_f = f } = eqninfo in
  let rec computations env prob f alias fsubst refine = function
  | Compute (lhs, where, ty, c) ->
     let where_comp w (wheres, where_comps) =
       (* Where term is in lhs + wheres *)
       let lhsterm = substl wheres (where_term w) in
       let term, args = decompose_app evd lhsterm in
       let alias, fsubst =
         try
           let (f, id, s) = PathMap.find w.where_path wheremap in
           let f, fargs = decompose_appvect evd f in
           let args = match_arguments evd (arguments evd (where_term w)) fargs in
           let fsubst = ((f, args), term) :: fsubst in
           (* Feedback.msg_info Pp.(str"Substituting " ++ Printer.pr_econstr_env env evd f ++
            *                       spc () ++
            *                       prlist_with_sep spc int args ++ str" by " ++
            *                       Printer.pr_econstr_env env evd term); *)
           Some ((f, args), id, s), fsubst
         with Not_found -> None, fsubst
       in
       let term_ty = Retyping.get_type_of env evd term in
       let subterm, filter =
         let rec aux ty i args' =
           match kind evd ty, args' with
           | Prod (na, b, ty), a :: args' ->
             if EConstr.isRel evd a then (* A variable from the context that was not substituted
                                  by a recursive prototype, we keep it *)
               let term', len = aux ty (succ i) args' in
               mkLambda (na, b, term'), i :: len
             else
               (* The argument was substituted, we keep that substitution *)
               let term', len = aux (subst1 a ty) (succ i) args' in
               term', len
           | _, [] -> lhsterm, []
           | _, _ :: _ -> assert false
         in aux term_ty 0 args
       in
       let wsmash, smashsubst = smash_ctx_map env evd (id_subst w.where_program.program_info.program_sign) in
       let comps = computations env wsmash subterm None fsubst (Regular,false)
           w.where_program.program_splitting in
       let arity = w.where_program.program_info.program_arity in
       let termf =
         if not (PathMap.is_empty wheremap) then
           subterm, [0]
         else
           subterm, filter
       in
       let where_comp =
         (termf, alias, w.where_orig, pi1 wsmash, (* substl smashsubst *) arity,
          pattern_instance wsmash,
          [] (*?*), comps)
       in (lhsterm :: wheres, where_comp :: where_comps)
     in
     let inst, wheres = List.fold_right where_comp where ([],[]) in
     let ctx = compose_subst env ~sigma:evd lhs prob in
     if !Equations_common.debug then
       Feedback.msg_debug Pp.(str"where_instance: " ++ prlist_with_sep spc (Printer.pr_econstr_env env evd) inst);
     let fn c =
       let c' = Reductionops.nf_beta env evd (substl inst c) in
       substitute_aliases evd fsubst c'
     in
     let c' = map_rhs (fun c -> fn c) (fun x -> x) c in
     let patsconstrs = pattern_instance ctx in
     let ty = substl inst ty in
     [pi1 ctx, f, alias, patsconstrs, ty,
      f, (Where, snd refine), c', Some wheres]

  | Split (_, _, _, cs) ->
    Array.fold_left (fun acc c ->
        match c with
   | None -> acc
   | Some c ->
   acc @ computations env prob f alias fsubst refine c) [] cs

  | Mapping (lhs, c) ->
     let _newprob = compose_subst env ~sigma:evd prob lhs in
     computations env prob f alias fsubst refine c

  | RecValid (lhs, id, r, cs) ->
    let subst = compose_subst env ~sigma:evd r.rec_prob prob in
    computations env subst f alias fsubst (fst refine, false) cs

  | Refined (lhs, info, cs) ->
     let (id, c, t) = info.refined_obj in
     let (ctx', pats', _ as s) = compose_subst env ~sigma:evd lhs prob in
     let patsconstrs = pattern_instance s in
     let refineds = compose_subst env ~sigma:evd info.refined_newprob_to_lhs s in
     let refinedpats = pattern_instance refineds in
     let filter = [Array.length (arguments evd info.refined_term)] in
     [pi1 lhs, f, alias, patsconstrs, info.refined_rettyp, f, (Refine, true),
      RProgram (applistc info.refined_term info.refined_args),
      Some [(info.refined_term, filter), None, info.refined_path, pi1 info.refined_newprob,
            info.refined_newty, refinedpats,
            [mapping_constr evd info.refined_newprob_to_lhs c, info.refined_arg],
            computations env info.refined_newprob info.refined_term None fsubst (Regular, true) cs]]

  in computations env prob f alias [] refine p.program_splitting

let constr_of_global_univ gr u =
  let open Globnames in
  match gr with
  | ConstRef c -> mkConstU (c, u)
  | IndRef i -> mkIndU (i, u)
  | ConstructRef c -> mkConstructU (c, u)
  | VarRef id -> mkVar id

let declare_funelim info env evd is_rec protos progs
                    ind_stmts all_stmts sign app subst inds kn comb
                    indgr ectx =
  let id = Id.of_string info.base_id in
  let leninds = List.length inds in
  let elim =
    if leninds > 1 || Lazy.force logic_sort != Sorts.InProp then comb
    else
      let elimid = Nameops.add_suffix id "_ind_ind" in
      Smartlocate.global_with_alias (Libnames.qualid_of_ident elimid)
  in
  let elimc, elimty =
    let elimty, uctx = Typeops.type_of_global_in_context (Global.env ()) elim in
    let () = evd := Evd.from_env (Global.env ()) in
    if is_polymorphic info then
      (* We merge the contexts of the term and eliminator in which
         ind_stmts and all_stmts are derived, universe unification will
         take care of unifying the eliminator's fresh instance with the
         universes of the constant and the functional induction lemma. *)
      let () = evd := Evd.merge_universe_context !evd info.term_ustate in
      let () = evd := Evd.merge_universe_context !evd ectx in
      let sigma, elimc = Evarutil.new_global !evd elim in
      let elimty = Retyping.get_type_of env sigma elimc in
      let () = evd := sigma in
      elimc, elimty
    else (* If not polymorphic, we just use the global environment's universes for f and elim *)
      (let elimc = constr_of_global_univ elim EInstance.empty in
       elimc, of_constr elimty)
  in
  let nargs, newty =
    compute_elim_type env evd info.user_obls is_rec protos kn leninds ind_stmts all_stmts
                      sign app elimty
  in
  let hookelim _ _ _ elimgr =
    let env = Global.env () in
    let evd = Evd.from_env env in
    let f_gr = Nametab.locate (Libnames.qualid_of_ident id) in
    let evd, f = new_global evd f_gr in
    let evd, elimcgr = new_global evd elimgr in
    let evd, cl = functional_elimination_class evd in
    let args_of_elim = coq_nat_of_int nargs in
    let args = [Retyping.get_type_of env evd f; f;
                Retyping.get_type_of env evd elimcgr;
                of_constr args_of_elim; elimcgr]
    in
    let instid = Nameops.add_prefix "FunctionalElimination_" id in
    let poly = is_polymorphic info in
    ignore(Equations_common.declare_instance instid poly evd [] cl args)
  in
  let tactic = ind_elim_tac elimc leninds (List.length progs) info indgr in
  let _ = e_type_of (Global.env ()) evd newty in
  ignore(Obligations.add_definition (Nameops.add_suffix id "_elim")
                                    ~tactic ~hook:(Lemmas.mk_hook hookelim) ~kind:info.decl_kind
                                    (to_constr !evd newty) (Evd.evar_universe_context !evd) [||])

let mkConj evd x y =
  let prod = get_efresh logic_conj evd in
    mkApp (prod, [| x; y |])

let declare_funind info alias env evd is_rec protos progs
                   ind_stmts all_stmts sign inds kn comb f split ind =
  let poly = is_polymorphic info.term_info in
  let id = Id.of_string info.term_info.base_id in
  let indid = Nameops.add_suffix id "_ind_fun" in
  (* Record nested statements which can be repeated during the proof *)
  let nested_statements = ref [] in
  let statement =
    let stmt (i, ((f,_), alias, path, sign, ar, _, _, (nodek, cut)), _) =
      if not (regular_or_nested nodek) then None else
      let f, split, unfsplit =
        match alias with
        | Some ((f,_), _, recsplit) -> f, recsplit, Some split
        | None -> f, split, None
      in
      let args = extended_rel_list 0 sign in
      let app = applist (f, args) in
      let ind = Nameops.add_suffix (path_id path)(* Id.of_string info.term_info.base_id) *)
                                   ("_ind" (* ^ if i == 0 then "" else "_" ^ string_of_int i *)) in
      let indt = e_new_global evd (global_reference ind) in
      let ty = it_mkProd_or_subst env !evd (applist (indt, args @ [app])) sign in
      let (prog, _, _, _) = List.find (fun (p, _, _, _) -> Id.equal p.program_info.program_id (path_id path)) progs in
      if nested nodek then nested_statements := (path_id path, ty, prog) :: !nested_statements;
      Some ty
    in
    match ind_stmts with
    | [] -> assert false
    | [hd] -> Option.get (stmt hd)
    | hd :: tl ->
       let l, last =
         let rec aux l =
           let last, l = CList.sep_last l in
           match stmt last with
           | None -> aux l
           | Some t -> t, l
         in aux ind_stmts
       in
       List.fold_right (fun x acc -> match stmt x with
                                     | Some t -> mkConj evd t acc
                                     | None -> acc) last l
  in
  let args = Termops.rel_list 0 (List.length sign) in
  let f =
    match alias with
    | Some ((f, _), _, _) -> f
    | None -> f
  in
  let app = applist (f, args) in
  let hookind ectx _obls subst indgr =
    let env = Global.env () in (* refresh *)
    Hints.add_hints ~local:false [info.term_info.base_id]
                    (Hints.HintsImmediateEntry [Hints.PathAny, poly, Hints.IsGlobRef indgr]);
    let () =
      try declare_funelim info.term_info env evd is_rec protos progs
            ind_stmts all_stmts sign app subst inds kn comb indgr ectx
      with e ->
        Feedback.msg_warning Pp.(str "Elimination principle could not be proved automatically: " ++ fnl () ++
                                 CErrors.print e);
    in
    let evd = Evd.from_env env in
    let f_gr = Nametab.locate (Libnames.qualid_of_ident id) in
    let evd, f = new_global evd f_gr in
    let evd, indcgr = new_global evd indgr in
    let evd, cl = functional_induction_class evd in
    let args = [Retyping.get_type_of env evd f; f;
                Retyping.get_type_of env evd indcgr; indcgr]
    in
    let instid = Nameops.add_prefix "FunctionalInduction_" id in
    ignore(Equations_common.declare_instance instid poly evd [] cl args);
    (* If desired the definitions should be made transparent again. *)
    if !Equations_common.equations_transparent then
      (Global.set_strategy (ConstKey (fst (destConst evd f))) Conv_oracle.transparent;
       match alias with
       | None -> ()
       | Some ((f, _), _, _) -> Global.set_strategy (ConstKey (fst (destConst evd f))) Conv_oracle.transparent)
    else
      ((* Otherwise we turn them opaque and let that information be discharged as well *)
        Lib.add_anonymous_leaf (inOpacity (fst (destConst evd f)));
        match alias with
        | None -> ()
        | Some ((f, _), _, _) -> Lib.add_anonymous_leaf (inOpacity (fst (destConst evd f))))
  in
  (* let evm, stmt = Typing.type_of (Global.env ()) !evd statement in *)
  let stmt = to_constr !evd statement and f = to_constr !evd f in
  let ctx = Evd.evar_universe_context (if poly then !evd else Evd.from_env (Global.env ())) in
  let launch_ind tactic =
    ignore(Obligations.add_definition
             ~hook:(Lemmas.mk_hook hookind)
             ~kind:info.term_info.decl_kind
             indid stmt ~tactic:(Tacticals.New.tclTRY tactic) ctx [||])
  in
  let tac = (ind_fun_tac is_rec f info id !nested_statements progs) in
  try launch_ind tac
  with e ->
    Feedback.msg_warning Pp.(str "Induction principle could not be proved automatically: " ++ fnl () ++
                             CErrors.print e);
    launch_ind (Proofview.tclUNIT ())


let level_of_context env evd ctx acc =
  let _, lev =
    List.fold_right (fun decl (env, lev) ->
        let s = Retyping.get_sort_of env evd (get_type decl) in
        (push_rel decl env, Univ.sup (Sorts.univ_of_sort s) lev))
                    ctx (env,acc)
  in lev

let all_computations env evd alias progs =
  let comps =
    let fn p unfp =
      let p = Option.default p unfp in
      computations env evd alias (kind_of_prog p.program_info,false) p in
    List.map (fun (p, unfp, prog, eqninfo) -> p, eqninfo, fn p unfp eqninfo) progs
  in
  let rec flatten_comp (ctx, fl, flalias, pats, ty, f, refine, c, rest) =
    let rest = match rest with
      | None -> []
      | Some l ->
         CList.map_append (fun (f, alias, path, ctx, ty, pats, newargs, rest) ->
          let nextlevel, rest = flatten_comps rest in
            ((f, alias, path, ctx, ty, pats, newargs, refine), nextlevel) :: rest) l
    in (ctx, fl, flalias, pats, ty, f, refine, c), rest
  and flatten_comps r =
    List.fold_right (fun cmp (acc, rest) ->
      let stmt, rest' = flatten_comp cmp in
        (stmt :: acc, rest' @ rest)) r ([], [])
  in
  let flatten_top_comps (p, eqninfo, one_comps) acc =
    let (top, rest) = flatten_comps one_comps in
    let pi = p.program_info in
    let topcomp = (((eqninfo.equations_f,[]), alias, [pi.program_id],
                    pi.program_sign, pi.program_arity,
                    List.rev_map pat_constr (pi2 eqninfo.equations_prob), [],
                    (kind_of_prog pi,false)), top) in
    topcomp :: (rest @ acc)
  in
  List.fold_right flatten_top_comps comps []

let unfold_fix =
  let open Proofview in
  Proofview.Goal.enter (fun gl ->
      let sigma = Goal.sigma gl in
      match kind sigma (Goal.concl gl) with
      | App (eq, [| _; lhs; _ |]) ->
        (match kind sigma lhs with
         | App (fn, args) ->
           (match kind sigma fn with
            | Fix ((indexes, p), decls) ->
              let fixarg = args.(indexes.(p)) in
              (match kind sigma fixarg with
               | Var id -> depelim_tac id
               | _ -> tclUNIT ())
            | _ -> tclUNIT ())
         | _ -> tclUNIT ())
      | _ -> tclUNIT ())

let build_equations with_ind env evd ?(alias:alias option) rec_info progs =
  let () =
    if !Equations_common.debug then
      let open Pp in
      let msg = Feedback.msg_debug in
      msg (str"Definining principles of: " ++
           prlist_with_sep fnl
             (fun (p, unfp, prog, eqninfo) ->
                pr_splitting env evd p.program_splitting ++ fnl () ++
                (match unfp with
                 | Some unf -> str "and " ++ pr_splitting env evd unf.program_splitting
                 | None -> mt ()))
             progs)
  in
  let env = Global.env () in
  let p, unfp, prog, eqninfo = List.hd progs in
  let user_obls =
    List.fold_left (fun acc (p, unfp, prog, eqninfo) ->
      Id.Set.union prog.program_split_info.user_obls acc) Id.Set.empty progs
  in
  let { equations_id = id;
        equations_where_map = wheremap;
        equations_f = f } = eqninfo in
  let info = prog.program_split_info in
  let sign = program_sign p in
  let cst = prog.program_cst in
  let comps = all_computations env evd alias progs in
  let protos = List.map fst comps in
  let lenprotos = List.length protos in
  let protos =
    CList.map_i (fun i ((f',filterf'), alias, path, sign, arity, pats, args, (refine, cut)) ->
      let f' = Termops.strip_outer_cast evd f' in
      let f'hd =
        let ctx, t = decompose_lam_assum evd f' in
        fst (decompose_app evd t)
      in
      let alias =
        match alias with
        | None -> None
        | Some (f, _, _) -> Some f
      in
      (f'hd, (f',filterf'), alias, lenprotos - i, sign, to_constr evd arity))
      1 protos
  in
  let evd = ref evd in
  let poly = is_polymorphic info in
  let statement i filter (ctx, fl, flalias, pats, ty, f', (refine, cut), c) =
    let hd, unf = match flalias with
      | Some ((f', _), unf, _) ->
        let tac = Proofview.tclBIND
            (Tacticals.New.pf_constr_of_global (Nametab.locate (Libnames.qualid_of_ident unf)))
            Equality.rewriteLR in
        f', tac

      | None -> fl,
        if eq_constr !evd fl f then
          Tacticals.New.tclORELSE Tactics.reflexivity
            (Tacticals.New.tclTHEN (of82 (unfold_constr !evd f)) unfold_fix)
        else Tacticals.New.tclIDTAC
    in
    let comp = applistc hd pats in
    let body =
      let nf_beta = Reductionops.nf_beta (push_rel_context ctx env) !evd in
      let b = match c with
        | RProgram c ->
            mkEq env evd ty (nf_beta comp) (nf_beta c)
        | REmpty (i, _) ->
           mkApp (coq_ImpossibleCall evd, [| ty; nf_beta comp |])
      in
      let body = it_mkProd_or_LetIn b ctx in
      if !Equations_common.debug then
        Feedback.msg_debug Pp.(str"Typing equation " ++ Printer.pr_econstr_env env !evd body);
      let _ = Equations_common.evd_comb1 (Typing.type_of env) evd body in
      body
    in
    let cstr =
      match c with
      | RProgram c ->
          let len = List.length ctx in
          let hyps, hypslen, c' =
            abstract_rec_calls !evd user_obls rec_info len protos (Reductionops.nf_beta env !evd c)
          in
          let head =
            let f = mkRel (len + (lenprotos - i) + hypslen) in
            if cut then f
            else
              let fn, args = decompose_app !evd (Termops.strip_outer_cast !evd fl) in
              applistc f (filter_arguments filter (lift_constrs hypslen args))
          in
          let ty =
            it_mkProd_or_clear !evd
              (it_mkProd_or_clean env !evd
                 (applistc head (lift_constrs hypslen pats @ [c']))
                 hyps) ctx
          in
          if !Equations_common.debug then
            Feedback.msg_debug Pp.(str"Typing constructor " ++ Printer.pr_econstr_env env !evd ty);

          Some ty
      | REmpty (i, _) -> None
    in (refine, unf, body, cstr)
  in
  let statements i ((f', alias, path, sign, arity, pats, args, refine as fs), c) =
    let fs, filter =
      match alias with
      | Some (f', unf, split) ->
         (f', None, path, sign, arity, pats, args, refine), snd f'
      | None -> fs, snd f'
    in fs, List.map (statement i filter) c in
  let stmts = CList.map_i statements 0 comps in
  let ind_stmts = CList.map_i
    (fun i (f, c) -> i, f, CList.map_i (fun j x -> j, x) 1 c) 0 stmts
  in
  let all_stmts = List.concat (List.map (fun (f, c) -> c) stmts) in
  let fnind_map = ref PathMap.empty in
  let declare_one_ind (i, (f, alias, path, sign, arity, pats, refs, refine), stmts) =
    let indid = Nameops.add_suffix (path_id path) "_ind" (* (if i == 0 then "_ind" else ("_ind_" ^ string_of_int i)) *) in
    let indapp = List.rev_map (fun x -> Constr.mkVar (Nameops.Name.get_id (get_name x))) sign in
    let () = fnind_map := PathMap.add path (indid,indapp) !fnind_map in
    let constructors = CList.map_filter (fun (_, (_, _, _, n)) -> Option.map (to_constr !evd) n) stmts in
    let consnames = CList.map_filter (fun (i, (r, _, _, n)) ->
      Option.map (fun _ ->
        let suff = (if r != Refine then "_equation_" else "_refinement_") ^ string_of_int i in
          Nameops.add_suffix indid suff) n) stmts
    in
    let ind_sort =
      if Lazy.force logic_sort == Sorts.InProp then
        (* Define graph impredicatively *)
        mkProp
      else (* Compute sort as max of products *)
        let ctx = (of_tuple (Anonymous, None, arity) :: sign) in
        let signlev = level_of_context env !evd ctx Univ.type0m_univ in
        mkSort (Sorts.sort_of_univ signlev)
    in
    (* let fullsign, arity = Reductionops.splay_prod_assum (push_rel_context sign env) !evd arity in *)
      Entries.{ mind_entry_typename = indid;
        mind_entry_arity = to_constr !evd (it_mkProd_or_LetIn (mkProd (Anonymous, arity, ind_sort)) (sign));
        mind_entry_consnames = consnames;
        mind_entry_lc = constructors;
        mind_entry_template = false }
  in
  let declare_ind () =
    let inds = List.map declare_one_ind ind_stmts in
    let uctx = Evd.univ_entry ~poly !evd in
    let inductive =
      Entries.{ mind_entry_record = None;
                mind_entry_universes = uctx;
                mind_entry_private = None;
                mind_entry_finite = Declarations.Finite;
                mind_entry_params = []; (* (identifier * local_entry) list; *)
                mind_entry_inds = inds;
                mind_entry_variance = None;
              }
    in
    let () = Goptions.set_bool_option_value_gen ~locality:Goptions.OptLocal ["Elimination";"Schemes"] false in
    let kn = ComInductive.declare_mutual_inductive_with_eliminations inductive UnivNames.empty_binders [] in
    let () = Goptions.set_bool_option_value_gen ~locality:Goptions.OptLocal ["Elimination";"Schemes"] true in
    let kn, comb =
      let sort = Lazy.force logic_sort in
      let suff = match sort with
        | Sorts.InProp -> "_ind"
        | Sorts.InSet ->  "_rec"
        | Sorts.InType -> "_rect"
      in
      let mutual =
        (CList.map_i (fun i ind ->
             let suff = if List.length inds != 1 then "_mut" else suff in
             let id = CAst.make @@ Nameops.add_suffix ind.Entries.mind_entry_typename suff in
             (id, false, (kn, i), sort)) 0 inds)
      in
      Indschemes.do_mutual_induction_scheme ~force_mutual:true mutual;
      if List.length inds != 1 then
        let scheme = Nameops.add_suffix (Id.of_string info.base_id) "_ind_comb" in
        let mutual = List.map2 (fun (i, _, _, _) (_, (_, _, _, _, _, _, _, (kind, cut)), _) ->
                         i, regular_or_nested_rec kind) mutual ind_stmts in
        let () =
          Indschemes.do_combined_scheme CAst.(make scheme)
            (CList.map_filter (fun (id, b) -> if b then Some id else None) mutual)
        in kn, Smartlocate.global_with_alias (Libnames.qualid_of_ident scheme)
      else
        let scheme = Nameops.add_suffix (Id.of_string info.base_id) ("_ind" ^ suff) in
        kn, Smartlocate.global_with_alias (Libnames.qualid_of_ident scheme)
    in
    let ind =
      let open Entries in
      match uctx with
      | Polymorphic_entry (_, uctx) ->
        mkIndU ((kn,0), EInstance.make (Univ.UContext.instance uctx))
      | Monomorphic_entry _ -> mkInd (kn,0)
    in
    let _ =
      List.iteri (fun i ind ->
        let constrs =
          CList.map_i (fun j _ -> Hints.empty_hint_info, poly, true, Hints.PathAny,
            Hints.IsGlobRef (Globnames.ConstructRef ((kn,i),j))) 1 ind.Entries.mind_entry_lc in
          Hints.add_hints ~local:false [info.base_id] (Hints.HintsResolveEntry constrs))
        inds
    in
    let info = { term_info = info; pathmap = !fnind_map; wheremap } in
    declare_funind info alias (Global.env ()) evd rec_info protos progs
                   ind_stmts all_stmts sign inds kn comb
                   f p.program_splitting ind
  in
  let () = evd := Evd.minimize_universes !evd in
  let () =
    if not poly then
      (* Declare the universe context necessary to typecheck the following
          definitions once and for all. *)
      (Declare.declare_universe_context false (Evd.universe_context_set !evd);
       evd := Evd.from_env (Global.env ()))
    else ()
  in
  let proof (j, (_, alias, path, sign, arity, pats, refs, refine), stmts) =
    let eqns = Array.make (List.length stmts) false in
    let id = path_id path in (* if j != 0 then Nameops.add_suffix id ("_helper_" ^ string_of_int j) else id in *)
    let proof (i, (r, unf, c, n)) =
      let ideq = Nameops.add_suffix id ("_equation_" ^ string_of_int i) in
      let hook _ _obls subst gr =
        if n != None then
          Lib.add_anonymous_leaf (inRewRules (info.base_id, gr))
        else (Typeclasses.declare_instance None true gr
              (* Hints.add_hints ~local:false [info.base_id]  *)
              (*                 (Hints.HintsExternEntry *)
              (*                  (Vernacexpr.{hint_priority = Some 0; hint_pattern = None}, *)
              (*                   impossible_call_tac (Globnames.ConstRef cst))) *));
        eqns.(pred i) <- true;
        if CArray.for_all (fun x -> x) eqns then (
          (* From now on, we don't need the reduction behavior of the constant anymore *)
          Typeclasses.set_typeclass_transparency (EvalConstRef cst) false false;
          (match alias with
           | Some ((f, _), _, _) ->
              Global.set_strategy (ConstKey (fst (destConst !evd f))) Conv_oracle.Opaque
           | None -> ());
          Global.set_strategy (ConstKey cst) Conv_oracle.Opaque;
          if with_ind && succ j == List.length ind_stmts then declare_ind ())
      in
      let tac =
        let open Tacticals.New in
        tclTHENLIST
          [Tactics.intros;
           unf;
           (solve_equation_tac (Globnames.ConstRef cst));
           (if PathMap.is_empty wheremap then Tacticals.New.tclIDTAC
            else tclTRY (of82 (autorewrites (info.base_id ^ "_where"))));
           Tactics.reflexivity]
      in
      let () =
        (* Refresh at each equation, accumulating known constraints. *)
        if not poly then evd := Evd.from_env (Global.env ())
        else ()
      in
      ignore(Obligations.add_definition
               ~kind:info.decl_kind
               ideq (to_constr !evd c)
               ~tactic:tac ~hook:(Lemmas.mk_hook hook)
	       (Evd.evar_universe_context !evd) [||])
    in List.iter proof stmts
  in List.iter proof ind_stmts

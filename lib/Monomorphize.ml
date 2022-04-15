open Identifier
open Env
open Type
open TypeStripping
open MonoType
open Tast
open Mtast
open Linked
open Id
open Error

(* Monomorphize type specifiers *)

let rec monomorphize_ty (env: env) (ty: stripped_ty): (mono_ty * env) =
  match ty with
  | SUnit ->
    (MonoUnit, env)
  | SBoolean ->
    (MonoBoolean, env)
  | SInteger (s, w) ->
    (MonoInteger (s, w), env)
  | SSingleFloat ->
    (MonoSingleFloat, env)
  | SDoubleFloat ->
    (MonoDoubleFloat, env)
  | SRegionTy r ->
    (MonoRegionTy r, env)
  | SArray (elem_ty, region) ->
    let (elem_ty, env) = monomorphize_ty env elem_ty in
    (MonoArray (elem_ty, region), env)
  | SReadRef (ty, region) ->
    let (ty, env) = monomorphize_ty env ty in
    let (region, env) = monomorphize_ty env region in
    (MonoReadRef (ty, region), env)
  | SWriteRef (ty, region) ->
    let (ty, env) = monomorphize_ty env ty in
    let (region, env) = monomorphize_ty env region in
    (MonoWriteRef (ty, region), env)
  | SRawPointer ty ->
    let (ty, env) = monomorphize_ty env ty in
    (MonoRawPointer ty, env)
  | SNamedType (name, args) ->
    let (args, env) = monomorphize_ty_list env args in
    (match get_decl_by_name env (qident_to_sident name) with
     | Some decl ->
       (match decl with
        | TypeAlias { id; _} ->
          let (env, mono_id) = add_or_get_type_alias_monomorph env id args in
          (MonoNamedType mono_id, env)
        | Record { id; _ } ->
          let (env, mono_id) = add_or_get_record_monomorph env id args in
          (MonoNamedType mono_id, env)
        | Union { id; _ } ->
          let (env, mono_id) = add_or_get_union_monomorph env id args in
          (MonoNamedType mono_id, env)
        | _ ->
          err "internal: named type points to something that isn't a type")
     | None ->
       err "internal")
  | SMonoTy id ->
    (MonoNamedType id, env)

and monomorphize_ty_list (env: env) (tys: stripped_ty list): (mono_ty list * env) =
  match tys with
  | first::rest ->
     let (first, env) = monomorphize_ty env first in
     let (rest, env) = monomorphize_ty_list env rest in
     (first :: rest, env)
  | [] ->
     ([], env)

let strip_and_mono (env: env) (ty: ty): (mono_ty * env) =
  let ty = strip_type ty in
  monomorphize_ty env ty

let strip_and_mono_list (env: env) (tys: ty list): (mono_ty list * env) =
  let tys = List.map strip_type tys in
  monomorphize_ty_list env tys

(* Monomorphize expressions *)

let rec monomorphize_expr (env: env) (expr: texpr): (mexpr * env) =
  match expr with
  | TNilConstant ->
     (MNilConstant, env)
  | TBoolConstant b ->
     (MBoolConstant b, env)
  | TIntConstant i ->
     (MIntConstant i, env)
  | TFloatConstant f ->
     (MFloatConstant f, env)
  | TStringConstant s ->
     (MStringConstant s, env)
  | TVariable (name, ty) ->
     let (ty, env) = strip_and_mono env ty in
     (MVariable (name, ty), env)
  | TArithmetic (oper, lhs, rhs) ->
     let (lhs, env) = monomorphize_expr env lhs in
     let (rhs, env) = monomorphize_expr env rhs in
     (MArithmetic (oper, lhs, rhs), env)
  | TFuncall (decl_id, name, args, rt, substs) ->
     (* Monomorphize the return type. *)
     let (rt, env) = strip_and_mono env rt in
     (* Monomorphize the arglist *)
     let (args, env) = monomorphize_expr_list env args in
     (* Does the funcall have a substitution list? *)
     if List.length substs > 0 then
       (* The function is generic. *)
       (* Monomorphize the tyargs *)
       let tyargs = List.map (fun (_, ty) -> strip_type ty) substs in
       let (tyargs, env) = monomorphize_ty_list env tyargs in
       let (env, mono_id) = add_or_get_function_monomorph env decl_id tyargs in
       (MGenericFuncall (mono_id, args, rt), env)
     else
       (* The function is concrete. *)
       (MConcreteFuncall (decl_id, name, args, rt), env)
  | TMethodCall (ins_meth_id, name, typarams, args, rt, substs) ->
     (* Monomorphize the return type. *)
     let (rt, env) = strip_and_mono env rt in
     (* Monomorphize the arglist *)
     let (args, env) = monomorphize_expr_list env args in
     (* Does the funcall have a list of type params? *)
     if List.length typarams > 0 then
       (* The instance is generic. *)
       (* Monomorphize the tyargs *)
       let tyargs = List.map (fun (_, ty) -> strip_type ty) substs in
       let (tyargs, env) = monomorphize_ty_list env tyargs in
       let (env, mono_id) = add_or_get_instance_method_monomorph env ins_meth_id tyargs in
       (MGenericMethodCall (ins_meth_id, mono_id, args, rt), env)
     else
       (* The instance is concrete. *)
       (MConcreteMethodCall (ins_meth_id, name, args, rt), env)
  | TCast (expr, ty) ->
     let (ty, env) = strip_and_mono env ty in
     let (expr, env) = monomorphize_expr env expr in
     (MCast (expr, ty), env)
  | TComparison (oper, lhs, rhs) ->
     let (lhs, env) = monomorphize_expr env lhs in
     let (rhs, env) = monomorphize_expr env rhs in
     (MComparison (oper, lhs, rhs), env)
  | TConjunction (lhs, rhs) ->
     let (lhs, env) = monomorphize_expr env lhs in
     let (rhs, env) = monomorphize_expr env rhs in
     (MConjunction (lhs, rhs), env)
  | TDisjunction (lhs, rhs) ->
     let (lhs, env) = monomorphize_expr env lhs in
     let (rhs, env) = monomorphize_expr env rhs in
     (MDisjunction (lhs, rhs), env)
  | TNegation expr ->
     let (expr, env) = monomorphize_expr env expr in
     (MNegation expr, env)
  | TIfExpression (c, t, f) ->
     let (c, env) = monomorphize_expr env c in
     let (t, env) = monomorphize_expr env t in
     let (f, env) = monomorphize_expr env f in
     (MIfExpression (c, t, f), env)
  | TRecordConstructor (ty, args) ->
     let (ty, env) = strip_and_mono env ty in
     let (args, env) = monomorphize_named_expr_list env args in
     (MRecordConstructor (ty, args), env)
  | TUnionConstructor (ty, case_name, args) ->
     let (ty, env) = strip_and_mono env ty in
     let (args, env) = monomorphize_named_expr_list env args in
     (MUnionConstructor (ty, case_name, args), env)
  | TTypeAliasConstructor (ty, expr) ->
     let (ty, env) = strip_and_mono env ty in
     let (expr, env) = monomorphize_expr env expr in
     (MTypeAliasConstructor (ty, expr), env)
  | TPath { head; elems; ty } ->
     let (ty, env) = strip_and_mono env ty in
     let (head, env) = monomorphize_expr env head in
     let (elems, env) = monomorphize_path_elems env elems in
     (MPath { head = head; elems = elems; ty = ty }, env)
  | TEmbed (ty, fmt, args) ->
     let (ty, env) = strip_and_mono env ty in
     let (args, env) = monomorphize_expr_list env args in
     (MEmbed (ty, fmt, args), env)
  | TDeref expr ->
     let (expr, env) = monomorphize_expr env expr in
     (MDeref expr, env)
  | TSizeOf ty ->
     let (ty, env) = strip_and_mono env ty in
     (MSizeOf ty, env)

and monomorphize_expr_list (env: env) (exprs: texpr list): (mexpr list * env) =
  match exprs with
  | first::rest ->
     let (first, env) = monomorphize_expr env first in
     let (rest, env) = monomorphize_expr_list env rest in
     (first :: rest, env)
  | [] ->
     ([], env)

and monomorphize_named_expr_list (env: env) (exprs: (identifier * texpr) list): ((identifier * mexpr) list * env) =
  match exprs with
  | (name, first)::rest ->
     let (first, env) = monomorphize_expr env first in
     let (rest, env) = monomorphize_named_expr_list env rest in
     ((name, first) :: rest, env)
  | [] ->
     ([], env)

and monomorphize_path_elems (env: env) (elems: typed_path_elem list): (mtyped_path_elem list * env) =
  match elems with
  | first::rest ->
     let (first, env) = monomorphize_path_elem env first in
     let (rest, env) = monomorphize_path_elems env rest in
     (first :: rest, env)
  | [] ->
     ([], env)

and monomorphize_path_elem (env: env) (elem: typed_path_elem): (mtyped_path_elem * env) =
  match elem with
  | TSlotAccessor (name, ty) ->
     let ty = strip_type ty in
     let (ty, env) = monomorphize_ty env ty in
     (MSlotAccessor (name, ty), env)
  | TPointerSlotAccessor (name, ty) ->
     let ty = strip_type ty in
     let (ty, env) = monomorphize_ty env ty in
     (MPointerSlotAccessor (name, ty), env)
  | TArrayIndex (idx, ty) ->
     let ty = strip_type ty in
     let (ty, env) = monomorphize_ty env ty in
     let (idx, env) = monomorphize_expr env idx in
     (MArrayIndex (idx, ty), env)

(* Monomorphize statements *)

let rec monomorphize_stmt (env: env) (stmt: tstmt): (mstmt * env) =
  match stmt with
  | TSkip _ ->
     (MSkip, env)
  | TLet (_, name, ty, value, body) ->
     let (ty, env) = strip_and_mono env ty in
     let (value, env) = monomorphize_expr env value in
     let (body, env) = monomorphize_stmt env body in
     (MLet (name, ty, value, body), env)
  | TDestructure (_, bindings, value, body) ->
     let (bindings, env) = monomorphize_named_ty_list env (List.map (fun (n, t) -> (n, strip_type t)) bindings) in
     let (value, env) = monomorphize_expr env value in
     let (body, env) = monomorphize_stmt env body in
     (MDestructure (bindings, value, body), env)
  | TAssign (_, lvalue, value) ->
     let (lvalue, env) = monomorphize_lvalue env lvalue in
     let (value, env) = monomorphize_expr env value in
     (MAssign (lvalue, value), env)
  | TIf (_, c, t, f) ->
     let (c, env) = monomorphize_expr env c in
     let (t, env) = monomorphize_stmt env t in
     let (f, env) = monomorphize_stmt env f in
     (MIf (c, t, f), env)
  | TCase (_, value, whens) ->
     let (value, env) = monomorphize_expr env value in
     let (whens, env) = monomorphize_whens env whens in
     (MCase (value, whens), env)
  | TWhile (_, value, body) ->
     let (value, env) = monomorphize_expr env value in
     let (body, env) = monomorphize_stmt env body in
     (MWhile (value, body), env)
  | TFor (_, name, start, final, body) ->
     let (start, env) = monomorphize_expr env start in
     let (final, env) = monomorphize_expr env final in
     let (body, env) = monomorphize_stmt env body in
     (MFor (name, start, final, body), env)
  | TBorrow { span; original; rename; region; orig_type; ref_type; body; mode } ->
     let _ = span in
     let (orig_type, env) = strip_and_mono env orig_type in
     let (ref_type, env) = strip_and_mono env ref_type in
     let (body, env) = monomorphize_stmt env body in
     (MBorrow { original = original; rename = rename; region = region; orig_type = orig_type; ref_type = ref_type; body = body; mode = mode }, env)
  | TBlock (_, a, b) ->
     let (a, env) = monomorphize_stmt env a in
     let (b, env) = monomorphize_stmt env b in
     (MBlock (a, b), env)
  | TDiscarding (_, value) ->
     let (value, env) = monomorphize_expr env value in
     (MDiscarding value, env)
  | TReturn (_, value) ->
     let (value, env) = monomorphize_expr env value in
     (MReturn value, env)

and monomorphize_lvalue (env: env) (lvalue: typed_lvalue): (mtyped_lvalue * env) =
  match lvalue with
  | TypedLValue (name, elems) ->
     let (elems, env) = monomorphize_path_elems env elems in
     (MTypedLValue (name, elems), env)

and monomorphize_whens (env: env) (whens: typed_when list): (mtyped_when list * env) =
  match whens with
  | first::rest ->
     let (first, env) = monomorphize_when env first in
     let (rest, env) = monomorphize_whens env rest in
     (first :: rest, env)
  | [] ->
     ([], env)

and monomorphize_when (env: env) (w: typed_when): (mtyped_when * env) =
  let (TypedWhen (name, params, body)) = w in
  let (params, env) = monomorphize_params env params in
  let (body, env) = monomorphize_stmt env body in
  (MTypedWhen (name, params, body), env)

and monomorphize_params (env: env) (params: value_parameter list): (mvalue_parameter list * env) =
  match params with
  | first::rest ->
     let (first, env) = monomorphize_param env first in
     let (rest, env) = monomorphize_params env rest in
     (first :: rest, env)
  | [] ->
     ([], env)

and monomorphize_param (env: env) (param: value_parameter): (mvalue_parameter * env) =
  let (ValueParameter (name, ty)) = param in
  let (ty, env) = strip_and_mono env ty in
  (MValueParameter (name, ty), env)

and monomorphize_named_ty_list (env: env) (tys: (identifier * stripped_ty) list): ((identifier * mono_ty) list * env) =
  match tys with
  | (name, first)::rest ->
     let (first, env) = monomorphize_ty env first in
     let (rest, env) = monomorphize_named_ty_list env rest in
     ((name, first) :: rest, env)
  | [] ->
     ([], env)

(* Monomorphize declarations *)

let rec monomorphize_decl (env: env) (decl: typed_decl): (mdecl option * env) =
  match decl with
  | TConstant (id, _, name, ty, value, _) ->
    (* Constant are intrinsically monomorphic, and can be monomorphized
       painlessly. *)
    let (ty, env) = strip_and_mono env ty in
    let (value, env) = monomorphize_expr env value in
    let decl = MConstant (id, name, ty, value) in
    (Some decl, env)
  | TTypeAlias (id, _, name, typarams, _, ty, _) ->
    (* Concrete (i.e., no type parameters) type aliases can be monomorphized
       immediately. Generic ones are monomorphized on demand. *)
    (match typarams with
     | [] ->
       let (ty, env) = strip_and_mono env ty in
       let decl = MTypeAlias (id, name, ty) in
       (Some decl, env)
     | _ ->
       (None, env))
  | TRecord (id, _, name, typarams, _, slots, _) ->
    (* Concrete records are monomorphized immediately. Generic records are
       monomorphized on demand. *)
    (match typarams with
     | [] ->
       let (env, slots) = monomorphize_slots env slots in
       let decl = MRecord (id, name, slots) in
       (Some decl, env)
     | _ ->
       (None, env))
  | TUnion (id, _, name, typarams, _, cases, _) ->
    (* Concrete unions are monomorphized immediately. Generic unions are
       monomorphized on demand. *)
    (match typarams with
     | [] ->
       let (env, cases) = Util.map_with_context (fun (e, c) -> monomorphize_case e c) env cases in
       let decl = MUnion (id, name, cases) in
       (Some decl, env)
     | _ ->
       (None, env))
  | TFunction (id, _, name, typarams, value_params, rt, body, _) ->
    (* Concrete functions are monomorphized immediately. Generic functions are
       monomorphized on demand. *)
    (match typarams with
     | [] ->
       let (env, params) = monomorphize_params env value_params in
       let (rt, env) = strip_and_mono env rt in
       let (body, env) = monomorphize_stmt env body in
       let decl = MFunction (id, name, params, rt, body) in
       (Some decl, env)
     | _ ->
       (None, env))
  | TForeignFunction (id, _, name, params, rt, underlying, _) ->
    (* Foreign functions are intrinsically monomorphic. *)
    let (env, params) = monomorphize_params env params in
    let (rt, env) = strip_and_mono env rt in
    let decl = MForeignFunction (id, name, params, rt, underlying) in
    (Some decl, env)
  | TTypeClass _ ->
    (* Type classes are purely "informative" declarations: they have no physical
       existence in the code. *)
    (None, env)
  | TInstance (decl_id, _, name, typarams, argument, methods, _) ->
    (* Concrete instances can be monomorphized immediately. *)
    (match typarams with
     | [] ->
       let (argument, env) = strip_and_mono env argument in
       let (env, methods) = monomorphize_methods env methods in
       let decl = MConcreteInstance (decl_id, name, argument, methods) in
       (Some decl, env)
     | _ ->
       (None, env))

and monomorphize_slot (env: env) (slot: typed_slot): (env * mono_slot) =
  let (TypedSlot (name, ty)) = slot in
  let (ty, env) = strip_and_mono env ty in
  (env, MonoSlot (name, ty))

and monomorphize_slots (env: env) (slots: typed_slot list): (env * mono_slot list) =
  Util.map_with_context (fun (e, s) -> monomorphize_slot e s) env slots

and monomorphize_case (env: env) (case: linked_case): (env * mono_case) =
  let (LCase (_, name, slots)) = case in
  let (env, slots) = monomorphize_slots env slots in
  (env, MonoCase (name, slots))

and monomorphize_param (env: env) (param: value_parameter): (env * mvalue_parameter) =
  let (ValueParameter (name, ty)) = param in
  let (ty, env) = strip_and_mono env ty in
  (env, MValueParameter (name, ty))

and monomorphize_params (env: env) (params: value_parameter list): (env * mvalue_parameter list) =
  Util.map_with_context (fun (e, p) -> monomorphize_param e p) env params

and monomorphize_methods (env: env) (methods: typed_method_def list): (env * concrete_method list) =
  Util.map_with_context (fun (e, m) -> monomorphize_method e m) env methods

and monomorphize_method (env: env) (meth: typed_method_def): (env * concrete_method) =
  let (TypedMethodDef (id, name, params, rt, body)) = meth in
  let (env, params) = monomorphize_params env params in
  let (rt, env) = strip_and_mono env rt in
  let (body, env) = monomorphize_stmt env body in
  (env, MConcreteMethod (id, name, params, rt, body))

(* Monomorphize modules *)

let rec monomorphize (env: env) (m: typed_module): (env * mono_module) =
  (* Monomorphize what we can: concrete definitions. *)
  let (TypedModule (module_name, decls)) = m in
  let (env, declopts) =
    Util.map_with_context (fun (e, d) -> let (d, e) = monomorphize_decl e d in (e, d)) env decls in
  let decls: mdecl list = List.filter_map (fun x -> x) declopts in
  (* Recursively collect and instantiate monomorphs until everything's instantiated. *)
  let (env, decls'): (env * mdecl list) = instantiate_monomorphs_until_exhausted env in
  (env, MonoModule (module_name, decls @ decls'))

and instantiate_monomorphs_until_exhausted (env: env): (env * mdecl list) =
  (* Get uninstantiated monomorphs from the environment. *)
  let monos: monomorph list = get_uninstantiated_monomorphs env in
  match monos with
  | first::rest ->
    (* If there are uninstantiated monomorphs, instantite them, and repeat the
       process. *)
    let (env, decls): (env * mdecl list) = instantiate_monomorphs env (first::rest) in
    let (env, decls') : (env * mdecl list) = instantiate_monomorphs_until_exhausted env in
    (env, decls @ decls')
  | [] ->
    (* If there are no uninstantiated monomorphs, we're done. *)
    (env, [])

and instantiate_monomorphs (env: env) (monos: monomorph list): (env * mdecl list) =
  (* Instantiate a list of monomorphs. *)
  Util.map_with_context (fun (e, m) -> instantiate_monomorph e m) env monos

and instantiate_monomorph (env: env) (mono: monomorph): (env * mdecl) =
  match mono with
  | MonoTypeAliasDefinition { id; type_id; tyargs; _ } ->
    (* Find the type alias declaration and extract the type parameters and the
       definition. *)
    let (typarams, ty) = get_type_alias_definition env type_id in
    (* Search/replace the type variables in `def` with the type arguments from
       this monomorph. *)
    let ty = replace_type_variables typarams tyargs ty in
    (* Strip and monomorphize the type. *)
    let (ty, env) = strip_and_mono env ty in
    (* Store the monomorphic type in the environment. *)
    let env = store_type_alias_monomorph_definition env id ty in
    (* Construct a monomorphic type alias decl. *)
    let decl: mdecl = MTypeAliasMonomorph (id, ty) in
    (* Return the new environment and the declaration. *)
    (env, decl)
  | MonoRecordDefinition { id; type_id; tyargs; _ } ->
     (* Find the record definition and extract the type parameters and the slot
        list. *)
     let (typarams, slots) = get_record_definition env type_id in
     (* Search/replace the type variables in the slot list with the type
        arguments from this monomorph. *)
     let slots: typed_slot list =
       List.map
         (fun (TypedSlot (name, ty)) ->
           TypedSlot (name, replace_type_variables typarams tyargs ty))
         slots
     in
     (* Strip and monomorphize the slot list. *)
     let (env, slots): (env * mono_slot list) = monomorphize_slot_list env slots in
     (* Store the monomorphic slot list in the environment. *)
     let env = store_record_monomorph_definition env id slots in
     (* Construct a monomorphic record decl. *)
     let decl: mdecl = MRecordMonomorph (id, slots) in
     (* Return the new environment and the declaration. *)
     (env, decl)
  | MonoUnionDefinition { id; type_id; tyargs; _ } ->
     (* Find the list of type parameters from the union definition. *)
     let typarams = get_union_typarams env type_id in
     (* Find the list of cases from the env. *)
     let cases: typed_case list = get_union_typed_cases env type_id in
     (* Search/replace the type variables in the case list with the type
        arguments from this monomorph. *)
     let cases: typed_case list =
       List.map
         (fun (TypedCase (name, slots)) ->
           let slots: typed_slot list =
             List.map
               (fun (TypedSlot (name, ty)) ->
                 TypedSlot (name, replace_type_variables typarams tyargs ty))
               slots
           in
           TypedCase (name, slots))
         cases
     in
     (* Strip and monomorphize the case list. *)
     let (env, cases): (env * mono_case list) = monomorphize_case_list env cases in
     (* Store the monomorphic slot list in the environment. *)
     let env = store_union_monomorph_definition env id cases in
     (* Construct a monomorphic record decl. *)
     let decl: mdecl = MUnionMonomorph (id, cases) in
     (* Return the new environment and the declaration. *)
     (env, decl)
  | _ ->
     err "not implemented yet"



(* Utils *)

and get_type_alias_definition (env: env) (id: decl_id): (type_parameter list * ty) =
  match get_decl_by_id env id with
  | Some (TypeAlias { typarams; def; _ }) ->
     (typarams, def)
  | _ ->
     err "internal"

and get_record_definition (env: env) (id: decl_id): (type_parameter list * typed_slot list) =
  match get_decl_by_id env id with
  | Some (Record { typarams; slots; _ }) ->
     (typarams, slots)
  | _ ->
     err "internal"

and get_union_typarams (env: env) (id: decl_id): type_parameter list =
  match get_decl_by_id env id with
  | Some (Union { typarams; _ }) ->
    typarams
  | _ ->
     err "internal"

and get_union_typed_cases (env: env) (union_id: decl_id): typed_case list =
  let cases: decl list = get_union_cases env union_id in
  let mapper (decl: decl): typed_case =
    match decl with
    | UnionCase { name; slots; _ } ->
       TypedCase (name, slots)
    | _ ->
       err "Internal: not a union"
  in
  List.map mapper cases

and monomorphize_slot_list (env: env) (slots: typed_slot list): (env * mono_slot list) =
  let names: identifier list = List.map (fun (TypedSlot (n, _)) -> n) slots in
  let (tys, env): (mono_ty list * env) = strip_and_mono_list env (List.map (fun (TypedSlot (_, t)) -> t) slots) in
  let (slots: mono_slot list) = List.map2 (fun name ty -> MonoSlot (name, ty)) names tys in
  (env, slots)

and monomorphize_case_list (env: env) (cases: typed_case list): (env * mono_case list) =
  Util.map_with_context
    (fun (env, TypedCase (name, slots)) ->
      let (env, slots) = monomorphize_slot_list env slots in
      (env, MonoCase (name, slots)))
    env
    cases

and replace_type_variables (typarams: type_parameter list) (args: mono_ty list) (ty: ty): ty =
  (* Given a list of type parameters, a list of monomorphic type arguments (of
     the same length), and a type expression, replace all instances of the type
     variables in the type expression with their corresponding argument
     (implicitly converting the `mono_ty` into a `ty`).

     Ideally we shouldn't need to bring the type parameters, rather, monomorphs
     should be stored in the environment with an `(identifier, mono_ty)` map
     rather than as a bare list of monomorphic type arguments. *)
  if (List.length typarams) <> (List.length args) then
    err "internal: not the same number of type parameters and type arguments"
  else
    let typaram_names: identifier list = List.map (fun (TypeParameter (n, _, _)) -> n) typarams in
    let args: ty list = List.map mono_to_ty args in
    (* Pray that this assumption is not violated. *)
    let combined: (identifier * ty) list = List.combine typaram_names args in
    replace_vars combined ty

and mono_to_ty (ty: mono_ty): ty =
  let r = mono_to_ty in
  match ty with
  | MonoUnit -> Unit
  | MonoBoolean -> Boolean
  | MonoInteger (s, w) -> Integer (s, w)
  | MonoSingleFloat -> SingleFloat
  | MonoDoubleFloat -> DoubleFloat
  | MonoNamedType mono_id ->
    (* SPECIAL CASE *)
    MonoTy mono_id
  | MonoArray (elem_ty, region) ->
    Array (r elem_ty, region)
  | MonoRegionTy r ->
    RegionTy r
  | MonoReadRef (ty, region) ->
    ReadRef (r ty, r region)
  | MonoWriteRef (ty, region) ->
    WriteRef (r ty, r region)
  | MonoRawPointer ty ->
    RawPointer (r ty)

and replace_vars (bindings: (identifier * ty) list) (ty: ty): ty =
  let r = replace_vars bindings in
  match ty with
  | Unit -> Unit
  | Boolean -> Boolean
  | Integer (s, w) -> Integer (s, w)
  | SingleFloat -> SingleFloat
  | DoubleFloat -> DoubleFloat
  | NamedType (name, args, u) ->
    NamedType (name, List.map r args, u)
  | Array (ty, region) ->
    Array (r ty, region)
  | RegionTy r ->
    RegionTy r
  | ReadRef (ty, reg) ->
    ReadRef (r ty, r reg)
  | WriteRef (ty, reg) ->
    WriteRef (r ty, r reg)
  | TyVar (TypeVariable (name, _, _)) ->
    List.assoc name bindings
  | RawPointer ty ->
    RawPointer (r ty)
  | MonoTy id ->
    MonoTy id

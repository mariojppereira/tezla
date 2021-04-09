open Core_kernel
open Env

let join_loop env_before env_after body =
  match (env_before, env_after) with
  | Stack env_before, Stack env_after ->
      List.fold2_exn ~init:body
        ~f:(fun acc before after ->
          if not (Adt.Var.equal before after) then
            let assign = Adt.create_stmt (S_assign (before, E_var after)) in
            Adt.create_stmt (S_seq (acc, assign))
          else acc)
        env_before env_after
  | _ ->
      Debug.amf [%here] "should not have reached here";
      assert false

let join env_t env_f s_f =
  let open Adt in
  match (env_t, env_f) with
  | Failed, env | env, Failed -> (env, s_f)
  | Stack env_t, Stack env_f ->
      assert (
        List.for_all2_exn
          ~f:(fun t f -> Typ.equal t.var_type f.var_type)
          env_t env_f);

      let s =
        List.fold2_exn env_t env_f ~init:s_f ~f:(fun acc v_t v_f ->
            let assign = create_stmt (S_assign (v_f, E_var v_t)) in
            create_stmt (S_seq (acc, assign)))
      in
      (Stack env_t, s)

let unlift_option_t t =
  let open Adt.Typ in
  match t with
  | T_option t -> t
  | _ ->
      let () = Debug.eprintf "Expected: option 'a but got %s\n" (to_string t) in
      assert false

let car_t t =
  let open Adt.Typ in
  match t with
  | T_pair (t, _) -> t
  | _ ->
      let () =
        Debug.eprintf "Expected: pair 'a 'b but got %s\n" (to_string t)
      in
      assert false

let cdr_t t =
  let open Adt.Typ in
  match t with
  | T_pair (_, t) -> t
  | _ ->
      let () =
        Debug.eprintf "Expected: pair 'a 'b but got %s\n" (to_string t)
      in
      assert false

let unlift_left_t t =
  let open Adt.Typ in
  match t with
  | T_or (t, _) -> t
  | _ ->
      let () = Debug.eprintf "Expected: or 'a 'b but got %s\n" (to_string t) in
      assert false

let unlift_right_t t =
  let open Adt.Typ in
  match t with
  | T_or (_, t) -> t
  | _ ->
      let () = Debug.eprintf "Expected: or 'a 'b but got %s\n" (to_string t) in
      assert false

let list_elem_t t =
  let open Adt.Typ in
  match t with
  | T_list t -> t
  | _ ->
      let () = Debug.eprintf "Expected: list 'a but got %s\n" (to_string t) in
      assert false

let map_iter_elem_t t =
  let open Adt.Typ in
  match t with
  | T_list t -> t
  | T_set t -> t
  | T_map (k, v) | T_big_map (k, v) -> T_pair (k, v)
  | _ ->
      let () =
        Debug.eprintf "Expected: list 'a or set 'a or map 'a 'b but got %s"
          (to_string t)
      in
      assert false

let lambda_t t =
  let open Adt.Typ in
  match t with
  | T_lambda (_, t) -> t
  | _ ->
      let () =
        Debug.eprintf "Expected: lambda 'a 'b but got %s\n" (to_string t)
      in
      assert false

let rec assert_type (_, d) (_, t, _) =
  let open Michelson.Carthage.Adt in
  match (d, t) with
  | D_int _, (T_int | T_nat | T_mutez | T_timestamp)
  | D_unit, T_unit
  | D_none, T_option _
  | ( D_string _,
      (T_string | T_key | T_key_hash | T_signature | T_address | T_timestamp) )
  | D_bytes _, (T_bytes | T_address)
  | D_bool _, T_bool ->
      true
  | D_pair (d_1, d_2), T_pair (t_1, t_2) ->
      assert_type d_1 t_1 && assert_type d_2 t_2
  | D_left d', T_or (t', _) | D_right d', T_or (_, t') | D_some d', T_option t'
    ->
      assert_type d' t'
  | D_list l, (T_list t' | T_set t') ->
      if List.length l = 0 then true
      else List.for_all ~f:(fun d' -> assert_type d' t') l
  | D_list l, (T_map (k, v) | T_big_map (k, v)) ->
      let assert_type_map d k v =
        match d with
        | D_elt (d_k, d_v) -> assert_type d_k k && assert_type d_v v
        | _ -> false
      in
      List.for_all ~f:(fun (_, d') -> assert_type_map d' k v) l
  | D_instruction _, T_lambda _ -> true
  | _ -> false

let rec typ_strip_location (_, t, a) =
  let open Michelson.Carthage.Adt in
  let t =
    match t with
    | T_option t -> T_option (typ_strip_location t)
    | T_or (t_1, t_2) -> T_or (typ_strip_location t_1, typ_strip_location t_2)
    | T_pair (t_1, t_2) ->
        T_pair (typ_strip_location t_1, typ_strip_location t_2)
    | T_set t -> T_set (typ_strip_location t)
    | T_big_map (t_1, t_2) ->
        T_big_map (typ_strip_location t_1, typ_strip_location t_2)
    | T_map (t_1, t_2) -> T_map (typ_strip_location t_1, typ_strip_location t_2)
    | T_contract t -> T_contract (typ_strip_location t)
    | T_lambda (t_1, t_2) ->
        T_lambda (typ_strip_location t_1, typ_strip_location t_2)
    | T_list t -> T_list (typ_strip_location t)
    | T_nat -> T_nat
    | T_key -> T_key
    | T_unit -> T_unit
    | T_signature -> T_signature
    | T_operation -> T_operation
    | T_chain_id -> T_chain_id
    | T_int -> T_int
    | T_string -> T_string
    | T_bytes -> T_bytes
    | T_mutez -> T_mutez
    | T_bool -> T_bool
    | T_key_hash -> T_key_hash
    | T_timestamp -> T_timestamp
    | T_address -> T_address
  in
  ((), t, a)

and data_strip_location (_, d) =
  let open Michelson.Carthage.Adt in
  let d =
    match d with
    | D_bool b -> D_bool b
    | D_unit -> D_unit
    | D_none -> D_none
    | D_int n -> D_int n
    | D_string s -> D_string s
    | D_bytes b -> D_bytes b
    | D_pair (d_1, d_2) ->
        D_pair (data_strip_location d_1, data_strip_location d_2)
    | D_left d -> D_left (data_strip_location d)
    | D_right d -> D_right (data_strip_location d)
    | D_some d -> D_some (data_strip_location d)
    | D_elt (d_1, d_2) ->
        D_elt (data_strip_location d_1, data_strip_location d_2)
    | D_list l -> D_list (List.map ~f:data_strip_location l)
    | D_instruction i -> D_instruction (inst_strip_location i)
  in
  ((), d)

and inst_strip_location (_, i, a) =
  let open Michelson.Carthage.Adt in
  let i =
    match i with
    | I_cast t -> I_cast (typ_strip_location t)
    | I_noop -> I_noop
    | I_failwith -> I_failwith
    | I_exec -> I_exec
    | I_apply -> I_apply
    | I_drop -> I_drop
    | I_dup -> I_dup
    | I_swap -> I_swap
    | I_unit -> I_unit
    | I_eq -> I_eq
    | I_neq -> I_neq
    | I_lt -> I_lt
    | I_gt -> I_gt
    | I_le -> I_le
    | I_ge -> I_ge
    | I_or -> I_or
    | I_and -> I_and
    | I_xor -> I_xor
    | I_not -> I_not
    | I_neg -> I_neg
    | I_abs -> I_abs
    | I_isnat -> I_isnat
    | I_int -> I_int
    | I_add -> I_add
    | I_sub -> I_sub
    | I_mul -> I_mul
    | I_ediv -> I_ediv
    | I_lsl -> I_lsl
    | I_lsr | I_compare -> I_compare
    | I_concat -> I_concat
    | I_size -> I_size
    | I_slice -> I_slice
    | I_pair -> I_pair
    | I_car -> I_car
    | I_cdr -> I_cdr
    | I_mem | I_update -> I_update
    | I_get -> I_get
    | I_some -> I_some
    | I_cons -> I_cons
    | I_transfer_tokens -> I_transfer_tokens
    | I_set_delegate | I_balance -> I_balance
    | I_address -> I_address
    | I_source -> I_source
    | I_sender -> I_sender
    | I_self -> I_self
    | I_amount | I_implicit_account -> I_implicit_account
    | I_now -> I_now
    | I_chain_id -> I_chain_id
    | I_pack -> I_pack
    | I_hash_key -> I_hash_key
    | I_blake2b | I_sha256 -> I_sha256
    | I_sha512 -> I_sha512
    | I_check_signature -> I_check_signature
    | I_unpair -> I_unpair
    | I_rename -> I_rename
    | I_seq l -> I_seq (List.map ~f:inst_strip_location l)
    | I_if (i_1, i_2) -> I_if (inst_strip_location i_1, inst_strip_location i_2)
    | I_loop i -> I_loop (inst_strip_location i)
    | I_loop_left i -> I_loop_left (inst_strip_location i)
    | I_dip i -> I_dip (inst_strip_location i)
    | I_dip_n (n, i) -> I_dip_n (n, inst_strip_location i)
    | I_drop_n n -> I_drop_n n
    | I_dig n -> I_dig n
    | I_dug n -> I_dug n
    | I_push (t, d) -> I_push (typ_strip_location t, data_strip_location d)
    | I_lambda (t_1, t_2, i) ->
        I_lambda
          (typ_strip_location t_1, typ_strip_location t_2, inst_strip_location i)
    | I_empty_set t -> I_empty_set (typ_strip_location t)
    | I_iter i -> I_iter (inst_strip_location i)
    | I_empty_map (t_1, t_2) ->
        I_empty_map (typ_strip_location t_1, typ_strip_location t_2)
    | I_map i -> I_map (inst_strip_location i)
    | I_empty_big_map (t_1, t_2) ->
        I_empty_big_map (typ_strip_location t_1, typ_strip_location t_2)
    | I_none t -> I_none (typ_strip_location t)
    | I_if_none (i_1, i_2) ->
        I_if_none (inst_strip_location i_1, inst_strip_location i_2)
    | I_left t -> I_left (typ_strip_location t)
    | I_right t -> I_right (typ_strip_location t)
    | I_if_left (i_1, i_2) ->
        I_if_left (inst_strip_location i_1, inst_strip_location i_2)
    | I_nil t -> I_nil (typ_strip_location t)
    | I_if_cons (i_1, i_2) ->
        I_if_cons (inst_strip_location i_1, inst_strip_location i_2)
    | I_contract t -> I_contract (typ_strip_location t)
    | I_unpack t -> I_unpack (typ_strip_location t)
    | I_create_contract { code; param; storage } ->
        let code = inst_strip_location code in
        let param = typ_strip_location param in
        let storage = typ_strip_location storage in
        I_create_contract { code; param; storage }
  in
  ((), i, a)

let rec convert_typ (_, t, _) =
  let open Adt.Typ in
  match t with
  | Michelson.Carthage.Adt.T_address -> T_address
  | Michelson.Carthage.Adt.T_key -> T_key
  | Michelson.Carthage.Adt.T_unit -> T_unit
  | Michelson.Carthage.Adt.T_signature -> T_signature
  | Michelson.Carthage.Adt.T_operation -> T_operation
  | Michelson.Carthage.Adt.T_chain_id -> T_chain_id
  | Michelson.Carthage.Adt.T_int -> T_int
  | Michelson.Carthage.Adt.T_nat -> T_nat
  | Michelson.Carthage.Adt.T_string -> T_string
  | Michelson.Carthage.Adt.T_bytes -> T_bytes
  | Michelson.Carthage.Adt.T_mutez -> T_mutez
  | Michelson.Carthage.Adt.T_bool -> T_bool
  | Michelson.Carthage.Adt.T_key_hash -> T_key_hash
  | Michelson.Carthage.Adt.T_timestamp -> T_timestamp
  | Michelson.Carthage.Adt.T_option t -> T_option (convert_typ t)
  | Michelson.Carthage.Adt.T_list t -> T_list (convert_typ t)
  | Michelson.Carthage.Adt.T_set t -> T_set (convert_typ t)
  | Michelson.Carthage.Adt.T_contract t -> T_contract (convert_typ t)
  | Michelson.Carthage.Adt.T_pair (t_1, t_2) ->
      T_pair (convert_typ t_1, convert_typ t_2)
  | Michelson.Carthage.Adt.T_or (t_1, t_2) ->
      T_or (convert_typ t_1, convert_typ t_2)
  | Michelson.Carthage.Adt.T_lambda (t_1, t_2) ->
      T_lambda (convert_typ t_1, convert_typ t_2)
  | Michelson.Carthage.Adt.T_map (t_1, t_2) ->
      T_map (convert_typ t_1, convert_typ t_2)
  | Michelson.Carthage.Adt.T_big_map (t_1, t_2) ->
      T_big_map (convert_typ t_1, convert_typ t_2)

let rec convert_data t (_, d) =
  let open Adt in
  let open Adt.Typ in
  match (t, d) with
  | _, Michelson.Carthage.Adt.D_int n -> D_int n
  | _, Michelson.Carthage.Adt.D_unit -> D_unit
  | _, Michelson.Carthage.Adt.D_none -> D_none
  | _, Michelson.Carthage.Adt.D_string s -> D_string s
  | _, Michelson.Carthage.Adt.D_bytes b -> D_bytes b
  | _, Michelson.Carthage.Adt.D_bool b -> D_bool b
  | T_pair (t_1, t_2), Michelson.Carthage.Adt.D_pair (d_1, d_2) ->
      D_pair (convert_data t_1 d_1, convert_data t_2 d_2)
  | T_or (t, _), Michelson.Carthage.Adt.D_left d -> D_left (convert_data t d)
  | T_or (_, t), Michelson.Carthage.Adt.D_right d -> D_right (convert_data t d)
  | T_option t, Michelson.Carthage.Adt.D_some d -> D_some (convert_data t d)
  | (T_list t | T_set t), Michelson.Carthage.Adt.D_list d_l ->
      D_list (List.map ~f:(convert_data t) d_l)
  | (T_map (t_1, t_2) | T_big_map (t_1, t_2)), Michelson.Carthage.Adt.D_list d_l
    ->
      D_list (List.map ~f:(convert_data_elt t_1 t_2) d_l)
  | T_lambda (t, _), Michelson.Carthage.Adt.D_instruction i ->
      let env =
        Env.push { var_name = "parameter"; var_type = t } Env.empty_env
      in
      let i, _ = inst_to_stmt (ref (-1)) env i in
      D_instruction i
  | _ -> assert false

and convert_data_elt t_1 t_2 (_, d) =
  let open Adt in
  match d with
  | Michelson.Carthage.Adt.D_elt (d_1, d_2) ->
      D_elt (convert_data t_1 d_1, convert_data t_2 d_2)
  | _ -> assert false

and inst_to_stmt counter env
    ((l, i, annots) :
      (Loc.t, Michelson.Carthage.Adt.annot list) Michelson.Carthage.Adt.inst) =
  let open Michelson.Carthage.Adt in
  let open Adt in
  let loop_n f =
    let rec loop acc n =
      if Bigint.(n = zero) then acc else loop (f acc n) Bigint.(n - one)
    in
    loop
  in
  let next_var () = next_var counter in
  let create_assign ?var_name e =
    let var_name = match var_name with None -> next_var () | Some v -> v in
    let var_type = Typer.type_expr e in
    let v = Var.{ var_name; var_type } in
    (v, create_stmt (S_assign (v, e)))
  in
  let create_assign_annot_1 e =
    let annots =
      List.filter ~f:(function A_var _ -> true | _ -> false) annots
    in
    match annots with
    | A_var var_name :: _ -> create_assign ~var_name e
    | _ -> create_assign e
  in
  let create_assign_annot_2 e =
    let annots =
      List.filter ~f:(function A_var _ -> true | _ -> false) annots
    in
    match annots with
    | _ :: A_var var_name :: _ -> create_assign ~var_name e
    | _ -> create_assign e
  in
  try
    match i with
    | I_failwith ->
        let x, _ = pop env in
        (create_stmt (S_failwith x), Failed)
    | I_seq i_l -> (
        match i_l with
        | [] -> (create_stmt S_skip, env)
        | h :: tl ->
            let s_h, env_h = inst_to_stmt counter env h in
            List.fold_left
              ~f:(fun (s, env) i ->
                let s', env' = inst_to_stmt counter env i in
                (create_stmt (S_seq (s, s')), env'))
              ~init:(s_h, env_h) tl)
    | I_if (i_t, i_f) ->
        let c, env' = pop env in
        let s_t, env_t = inst_to_stmt counter env' i_t in
        let s_f, env_f = inst_to_stmt counter env' i_f in
        let env', s_f' = join env_t env_f s_f in
        let s = create_stmt (S_if (c, s_t, s_f')) in
        (s, env')
    | I_loop i ->
        (*
          LOOP c {
            ... // body

            c := top;
            ... // join_loop
          }
        *)
        let c, env_before = pop env in
        let body, env' = inst_to_stmt counter env_before i in
        let top, env_after = pop env' in
        let assign_c = create_stmt (S_assign (c, E_var top)) in
        let body = create_stmt (S_seq (body, assign_c)) in
        let body = join_loop env_before env_after body in
        let s = create_stmt (S_loop (c, body)) in
        (s, env_after)
    | I_loop_left i ->
        let c, env_before = pop env in
        let e = E_unlift_or_left c in
        let v, assign_unlift = create_assign e in
        let body, env' =
          let body_env = push v env_before in
          inst_to_stmt counter body_env i
        in
        let top, env_after = pop env' in
        let assign_c = create_stmt (S_assign (c, E_var top)) in
        let body =
          create_stmt
            (S_seq (create_stmt (S_seq (assign_unlift, body)), assign_c))
        in
        let body = join_loop env_before env_after body in
        let post_loop_unlift = E_unlift_or_right c in
        let v_post_loop, post_loop_assign_unlift =
          create_assign post_loop_unlift
        in
        let s =
          create_stmt
            (S_seq (create_stmt (S_loop_left (c, body)), post_loop_assign_unlift))
        in
        let env' = push v_post_loop env_after in
        (s, env')
    | I_push (t, x) ->
        assert (assert_type x t);
        let t = convert_typ t in
        let d = convert_data t x in
        let e = E_push (d, t) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_drop ->
        let v, env' = pop env in
        (create_stmt (S_drop [ v ]), env')
    | I_drop_n n ->
        let env', l =
          loop_n
            (fun (env, l) _ ->
              let v, env = pop env in
              (env, v :: l))
            (env, []) n
        in
        (create_stmt (S_drop l), env')
    | I_dup ->
        let v = peek env in
        let e = E_dup v in
        let v', assign = create_assign_annot_1 e in
        let env' = push v' env in
        (assign, env')
    | I_dig n -> (create_stmt S_dig, dig env n)
    | I_dug n -> (create_stmt S_dug, dug env n)
    | I_swap ->
        let env' = swap env in
        (create_stmt S_swap, env')
    | I_some ->
        let v, env' = pop env in
        let e = E_some v in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_none t ->
        let t = convert_typ t in
        let e = E_none t in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_unit ->
        let e = E_unit in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_if_none (i_t, i_f) ->
        let v, env' = pop env in
        let s_t, env_t = inst_to_stmt counter env' i_t in
        let v', assign = create_assign (E_unlift_option v) in
        let s_f, env_f = inst_to_stmt counter (push v' env') i_f in
        let s_f = create_stmt (S_seq (assign, s_f)) in
        let env', s_f' = join env_t env_f s_f in
        let s = create_stmt (S_if_none (v, s_t, s_f')) in
        (s, env')
    | I_pair ->
        let v_1, env' = pop env in
        let t_2, env' = pop env' in
        let e = E_pair (v_1, t_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_car ->
        let v, env' = pop env in
        let e = E_car v in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_cdr ->
        let v, env' = pop env in
        let e = E_cdr v in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_left t ->
        let t = convert_typ t in
        let v, env' = pop env in
        let e = E_left (v, t) in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_right t ->
        let t = convert_typ t in
        let v, env' = pop env in
        let e = E_right (v, t) in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_if_left (i_t, i_f) ->
        let v, env' = pop env in
        let e_t = E_unlift_or_left v in
        let e_f = E_unlift_or_right v in
        let v_t, assign_t = create_assign e_t in
        let v_f, assign_f = create_assign e_f in
        let env_t = push v_t env' in
        let env_f = push v_f env' in
        let s_t, env_t = inst_to_stmt counter env_t i_t in
        let s_f, env_f = inst_to_stmt counter env_f i_f in
        let s_t = create_stmt (S_seq (assign_t, s_t)) in
        let s_f = create_stmt (S_seq (assign_f, s_f)) in
        let env', s_f' = join env_t env_f s_f in
        let s = create_stmt (S_if_left (v, s_t, s_f')) in
        (s, env')
    | I_nil t ->
        let t = convert_typ t in
        let e = E_nil t in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_cons ->
        let v_1, env' = pop env in
        let v_2, env' = pop env' in
        let e = E_cons (v_1, v_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_if_cons (i_t, i_f) ->
        let c, env' = pop env in
        let v_hd, assign_hd =
          let e_hd = E_hd c in
          create_assign e_hd
        in
        let v_tl, assign_tl =
          let e_tl = E_tl c in
          create_assign e_tl
        in
        let env_t = push v_hd (push v_tl env') in
        let env_f = env' in
        let s_t, env_t = inst_to_stmt counter env_t i_t in
        let s_t =
          create_stmt (S_seq (assign_hd, create_stmt (S_seq (assign_tl, s_t))))
        in
        let s_f, env_f = inst_to_stmt counter env_f i_f in
        let env', s_f' = join env_t env_f s_f in
        let s = create_stmt (S_if_cons (c, s_t, s_f')) in
        (s, env')
    | I_size ->
        let v, env' = pop env in
        let e = E_size v in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_empty_set t ->
        let t = convert_typ t in
        let e = E_empty_set t in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_empty_map (t_k, t_v) ->
        let t_k = convert_typ t_k in
        let t_v = convert_typ t_v in
        let e = E_empty_map (t_k, t_v) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_empty_big_map (t_k, t_v) ->
        let t_k = convert_typ t_k in
        let t_v = convert_typ t_v in
        let e = E_empty_big_map (t_k, t_v) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_map b ->
        (*
           acc := special_nil_list ();
           MAP c {
             v := hd c;

             // body
             ...
             top := ...;
             ...

             acc := append (acc, top);
             c := tl c;
           } *)
        let c, env' = pop env in
        let hd, assign_hd = create_assign (E_hd c) in
        let body, env_after_body =
          let body_env = push hd env' in
          inst_to_stmt counter body_env b
        in
        let assign_tl = create_stmt (S_assign (c, E_tl c)) in
        let body_result, env_after_loop = pop env_after_body in
        let acc, initial_acc_assign =
          match c.var_type with
          | T_list _ ->
              create_assign (E_special_empty_list body_result.var_type)
          | T_map (t, _) ->
              create_assign (E_special_empty_map (t, body_result.var_type))
          | _ -> assert false
        in
        let assign_append =
          create_stmt (S_assign (acc, E_append (acc, body_result)))
        in
        let body =
          create_stmt
            (S_seq
               ( assign_hd,
                 create_stmt
                   (S_seq (body, create_stmt (S_seq (assign_append, assign_tl))))
               ))
        in
        let s =
          create_stmt
            (S_seq (initial_acc_assign, create_stmt (S_map (c, body))))
        in
        (s, push acc env_after_loop)
    | I_iter b ->
        (*
           ITER c {
             v := hd c;

             // body
             ...
             
             c := tl c;
           } *)
        let c, env' = pop env in
        let hd, assign_hd = create_assign (E_hd c) in
        let body, env' =
          let body_env = push hd env' in
          inst_to_stmt counter body_env b
        in
        let assign_tl = create_stmt (S_assign (c, E_tl c)) in
        let body =
          create_stmt (S_seq (assign_hd, create_stmt (S_seq (body, assign_tl))))
        in
        let s = create_stmt (S_iter (c, body)) in
        (s, env')
    | I_mem ->
        let elt, env' = pop env in
        let set, env' = pop env' in
        let e = E_mem (elt, set) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_get ->
        let key, env' = pop env in
        let map, env' = pop env' in
        let e = E_get (key, map) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_update ->
        let key, env' = pop env in
        let value, env' = pop env' in
        let map, env' = pop env' in
        let e = E_update (key, value, map) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_lambda (t_1, t_2, i) ->
        let t_1 = convert_typ t_1 in
        let t_2 = convert_typ t_2 in
        let param = Var.{ var_name = next_var (); var_type = t_1 } in
        let b, lambda_env = inst_to_stmt counter (push param empty_env) i in
        let b =
          match lambda_env with
          | Failed -> b
          | Stack _ ->
              let r = peek lambda_env in
              create_stmt (S_seq (b, create_stmt (S_return r)))
        in
        let e = E_lambda (t_1, t_2, param, b) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_exec ->
        let param, env' = pop env in
        let lambda, env' = pop env' in
        let e = E_exec (param, lambda) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_dip i ->
        let x, env' = pop env in
        let s, env' = inst_to_stmt counter env' i in
        (s, push x env')
    | I_dip_n (n, i) ->
        let xl, env' = dip env n in
        let s, env' = inst_to_stmt counter env' i in
        let env' = List.fold_left ~f:(fun acc x -> push x acc) ~init:env' xl in
        (s, env')
    | I_cast _ -> (create_stmt S_skip, env)
    | I_rename -> (create_stmt S_skip, env)
    | I_concat ->
        let v, env' = pop env in
        let e, env' =
          match v.var_type with
          | T_list T_string | T_list T_bytes -> (E_concat_list v, env')
          | T_string | T_bytes ->
              let s_2, env' = pop env' in
              (E_concat (v, s_2), env')
          | _ -> assert false
        in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_slice ->
        let offset, env' = pop env in
        let length, env' = pop env' in
        let x, env' = pop env' in
        let e = E_slice (offset, length, x) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_pack ->
        let x, env' = pop env in
        let e = E_pack x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_unpack t ->
        let t = convert_typ t in
        let v, env' = pop env in
        let e = E_unpack (t, v) in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_add ->
        let v_1, env' = pop env in
        let v_2, env' = pop env' in
        let e = E_add (v_1, v_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_sub ->
        let v_1, env' = pop env in
        let v_2, env' = pop env' in
        let e = E_sub (v_1, v_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_mul ->
        let t_1, env' = pop env in
        let t_2, env' = pop env' in
        let e = E_mul (t_1, t_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_ediv ->
        let v_1, env' = pop env in
        let v_2, env' = pop env' in
        let e = E_div (v_1, v_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_abs ->
        let x, env' = pop env in
        let e = E_abs x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_neg ->
        let x, env' = pop env in
        let e = E_neg x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_lsl ->
        let x_1, env' = pop env in
        let x_2, env' = pop env' in
        let e = E_shiftL (x_1, x_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_lsr ->
        let x_1, env' = pop env in
        let x_2, env' = pop env' in
        let e = E_shiftR (x_1, x_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_or ->
        let x_1, env' = pop env in
        let x_2, env' = pop env' in
        let e = E_or (x_1, x_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_and ->
        let x_1, env' = pop env in
        let x_2, env' = pop env' in
        let e = E_and (x_1, x_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_xor ->
        let x_1, env' = pop env in
        let x_2, env' = pop env' in
        let e = E_xor (x_1, x_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_not ->
        let x, env' = pop env in
        let e = E_not x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_compare ->
        let x_1, env' = pop env in
        let x_2, env'' = pop env' in
        let e = E_compare (x_1, x_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env'')
    | I_eq ->
        let x, env' = pop env in
        let e = E_eq x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_neq ->
        let x, env' = pop env in
        let e = E_neq x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_lt ->
        let x, env' = pop env in
        let e = E_lt x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_gt ->
        let x, env' = pop env in
        let e = E_gt x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_le ->
        let x, env' = pop env in
        let e = E_leq x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_ge ->
        let x, env' = pop env in
        let e = E_geq x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_self ->
        let e = E_self in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_contract t ->
        let t = convert_typ t in
        let x, env' = pop env in
        let e = E_contract_of_address (t, x) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_transfer_tokens ->
        let x, env' = pop env in
        let amount, env' = pop env' in
        let contract, env' = pop env' in
        let operation = Operation.O_transfer_tokens (x, amount, contract) in
        let e = E_operation operation in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_set_delegate ->
        let x, env' = pop env in
        let o = Operation.O_set_delegate x in
        let e = E_operation o in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_create_contract c ->
        let delegate, env' = pop env in
        let amount, env' = pop env' in
        let storage, env' = pop env' in
        let o = Operation.O_create_contract (c, delegate, amount, storage) in
        let v_o, assign_o = create_assign_annot_1 (E_operation o) in
        let v_a, assign_a =
          create_assign_annot_2
            (E_create_contract_address (c, delegate, amount, storage))
        in
        let env' = push v_o (push v_a env') in
        (create_stmt (S_seq (assign_o, assign_a)), env')
    | I_implicit_account ->
        let v, env' = pop env in
        let e = E_implicit_account v in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_now ->
        let e = E_now in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_amount ->
        let e = E_amount in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_balance ->
        let e = E_balance in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_check_signature ->
        let key, env' = pop env in
        let signature, env' = pop env' in
        let bytes, env' = pop env' in
        let e = E_check_signature (key, signature, bytes) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_blake2b ->
        let x, env' = pop env in
        let e = E_blake2b x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_sha256 ->
        let v, env' = pop env in
        let e = E_sha256 v in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_sha512 ->
        let v, env' = pop env in
        let e = E_sha512 v in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_hash_key ->
        let v, env' = pop env in
        let e = E_hash_key v in
        let v', assign = create_assign_annot_1 e in
        (assign, push v' env')
    | I_source ->
        let e = E_source in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_sender ->
        let e = E_sender in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_address ->
        let x, env' = pop env in
        let e = E_address_of_contract x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_isnat ->
        let x, env' = pop env in
        let e = E_isnat x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_int ->
        let x, env' = pop env in
        let e = E_int_of_nat x in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env')
    | I_chain_id ->
        let e = E_chain_id in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
    | I_noop -> (create_stmt S_skip, env)
    | I_unpair ->
        let x, env' = pop env in
        let e = E_car x in
        let v_1, assign_1 = create_assign_annot_1 e in
        let e = E_cdr x in
        let v_2, assign_2 = create_assign_annot_2 e in
        (create_stmt (S_seq (assign_1, assign_2)), push v_1 (push v_2 env'))
    | I_apply ->
        let x_1, env = pop env in
        let x_2, env = pop env in
        let e = E_apply (x_1, x_2) in
        let v, assign = create_assign_annot_1 e in
        (assign, push v env)
  with
  | Functional_stack.Unsufficient_length ->
      failwith
        (Printf.sprintf "Unsufficent_length: Line %d, columns %d-%d\n"
           l.start_pos.lin l.start_pos.col l.end_pos.col)
  | Typer.Type_error e ->
      failwith
        (Printf.sprintf "Type error: %s, Line %d, columns %d-%d\n" e
           l.start_pos.lin l.start_pos.col l.end_pos.col)
  | Assert_failure (f, lin, col) ->
      failwith
        (Printf.sprintf
           "Assert failure on %s:%d:%d\n\
            Michelson file, Line %d, columns %d-%d\n"
           f lin col l.start_pos.lin l.start_pos.col l.end_pos.col)
  | Invalid_argument s ->
      failwith
        (Printf.sprintf
           "Invalid arguement: %s\nMichelson file, Line %d, columns %d-%d\n" s
           l.start_pos.lin l.start_pos.col l.end_pos.col)

and convert_program counter Michelson.Carthage.Adt.{ param; code; storage } =
  let param = convert_typ param in
  let storage = convert_typ storage in
  (* let code = inst_strip_location code in *)
  let env =
    Env.push
      { var_name = "parameter_storage"; var_type = T_pair (param, storage) }
      Env.empty_env
  in
  let code, env = inst_to_stmt counter env code in
  let code = Adt.simpl code in
  match env with
  | Failed -> (param, storage, code)
  | Stack _ ->
      let v = Env.peek env in
      let i = Adt.create_stmt (S_return v) in
      (param, storage, Adt.create_stmt (S_seq (code, i)))
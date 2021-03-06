(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2017 - OCamlPro SAS <contact@ocamlpro.com>            *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

[%%version 0.402]

type pending_state = {
  yetNeeded : nat;
  ownersDone : address set;
}

type transaction = {
  destination : UnitContract.instance;
  amount : tez;
}

type wallet_operation =
  | Withdraw of transaction
  | ChangeOwner of address * address
  | AddOwner of address
  | RemoveOwner of address
  | ChangeRequirement of nat
  | SetDailyLimit of tez
  | ResetSpentToday
  | Kill of UnitContract.instance

type operation_bytes = bytes

type storage = {
  m_required : nat;
  m_num_owners : nat;
  m_owners : address set;
  m_pending : (operation_bytes, pending_state) map;
  m_daily_limit : tez;
  m_spent_today : tez;
  m_last : timestamp;
}

let%init storage (owners : address set) (required : nat) (limit : tez) =
  let m_num_owners = Set.size owners in
  if required > m_num_owners then Current.failwith ();
  {
    m_num_owners;
    m_owners = owners;
    m_required = required;
    m_pending = (Map : (operation_bytes, pending_state) map);
    m_daily_limit = limit;
    m_spent_today = 0tz;
    m_last = Current.time ();
  }

let[@inline] no_op = ([] : operation list)

let[@inline] is_owner ((addr : address), (storage:storage)) =
  Set.mem addr storage.m_owners

let[@inline] onlyowner (storage:storage) =
  if is_owner (Current.source (), storage)
  then ()
  else Current.failwith ()

let[@inline] clearPending (storage : storage) =
  storage.m_pending <- (Map : (operation_bytes, pending_state) map)

type check_result =
  | Confirmations_Needed of storage
  | Execute of storage

let confirmAndCheck ((op : wallet_operation), (storage: storage)) =
  let owner = Current.source () in
  if not (is_owner (owner, storage)) then Current.failwith ();
  let op_bytes = Bytes.pack op in
  let pending = match Map.find op_bytes storage.m_pending with
    | None ->
      (* New operation *)
      { yetNeeded = storage.m_required;
        ownersDone = (Set : address set);
      }
    | Some pending ->
      (* Operation already registered but not executed *)
      pending
  in
  (* make sure we (the message sender) haven't confirmed this operation
     previously *)
  if Set.mem owner pending.ownersDone then Current.failwith ();
  (* check if count is enough to go ahead *)
  if pending.yetNeeded <= 1p then
    let storage =
      storage.m_pending <- (Map : (operation_bytes, pending_state) map) in
    Execute storage
  else
    let new_yetNeeded = match%nat int pending.yetNeeded - 1 with
      | Plus n -> n
      | Minus _ -> Current.failwith ()
    in
    let pending = pending.yetNeeded <- new_yetNeeded in
    let pending = pending.ownersDone <- Set.add owner pending.ownersDone in
    let storage = storage.m_pending <- Map.add op_bytes pending storage.m_pending in
    Confirmations_Needed storage
(* [@@inline] *)

(*
let only_enough_owners ((op : wallet_operation), (storage: storage)) =
  match confirmAndCheck (op, storage) with
  | Confirmations_Needed _ -> Current.failwith ()
  | Execute storage -> storage
[@@inline]
*)

(*
let has_confirmed ((op: wallet_operation), (owner: address), (storage:storage)) =
  match Map.find (Crypto.blake2b (Bytes.pack op)) storage.m_pending with
  | None -> false
  | Some pending -> Set.mem owner pending.ownersDone
[@@inline]
*)


(* Revokes a prior confirmation of the given operation *)
let%entry revoke (op : wallet_operation) storage =
  onlyowner storage;
  let owner = Current.source () in
  let op_bytes = Bytes.pack op in
  match Map.find op_bytes storage.m_pending with
  | None -> Current.failwith ()
  | Some pending ->
    if Set.mem owner pending.ownersDone then
      let pending = pending.yetNeeded <- pending.yetNeeded + 1p in
      let pending =
        pending.ownersDone <- Set.remove owner pending.ownersDone in
      no_op, storage.m_pending <- Map.add op_bytes pending storage.m_pending
    else no_op, storage



let%entry changeOwner (parameter : address * address) storage =
  (* let storage = only_enough_owners (ChangeOwner parameter, storage) in *)
  match confirmAndCheck (ChangeOwner parameter, storage) with
  | Confirmations_Needed storage -> no_op, storage
  | Execute storage ->
    let from, _to = parameter in
    if is_owner (_to, storage) || not (is_owner (from, storage))
    then Current.failwith ()
    else
      let storage = clearPending storage in
      let storage = storage.m_owners <- Set.remove from storage.m_owners in
      no_op, storage.m_owners <- Set.add _to storage.m_owners


let%entry addOwner (owner : address) storage =
  (* let storage = only_enough_owners (AddOwner owner, storage) in *)
  match confirmAndCheck (AddOwner owner, storage) with
  | Confirmations_Needed storage -> no_op, storage
  | Execute storage ->
    if is_owner (owner, storage) then Current.failwith ();
    let storage = clearPending storage in
    let storage = storage.m_num_owners <- storage.m_num_owners + 1p in
    no_op, storage.m_owners <- Set.add owner storage.m_owners


let%entry removeOwner (owner : address) storage =
  (* let storage = only_enough_owners (RemoveOwner owner, storage) in *)
  match confirmAndCheck (RemoveOwner owner, storage) with
  | Confirmations_Needed storage -> no_op, storage
  | Execute storage ->
    if not (is_owner (owner,storage)) then Current.failwith ();
    if storage.m_required >= storage.m_num_owners then Current.failwith ();
    let new_num_owners = match%nat int storage.m_num_owners - 1 with
      | Plus n -> n
      | Minus _ -> Current.failwith ()
    in
    let storage = storage.m_num_owners <- new_num_owners in
    let storage = storage.m_owners <- Set.remove owner storage.m_owners in
    no_op, clearPending storage


let%entry changeRequirement (required : nat) storage =
  (* let storage = only_enough_owners (ChangeRequirement required, storage) in *)
  match confirmAndCheck (ChangeRequirement required, storage) with
  | Confirmations_Needed storage -> no_op, storage
  | Execute storage ->
    if required > storage.m_num_owners then Current.failwith ();
    let storage = clearPending storage in
    no_op, storage.m_required <- required

let underLimit ((value: tez), (storage: storage)) =
  onlyowner storage;
  let storage =
    if Current.time () >= storage.m_last + 86400 (* 24h *) then
      let storage = storage.m_spent_today <- 0tz in
      storage.m_last <- Current.time ()
    else storage
  in
  if storage.m_spent_today + value <= storage.m_daily_limit then
    true, storage.m_spent_today <- storage.m_spent_today + value
  else
    false, storage

let%entry setDailyLimit (limit : tez) storage =
  (* let storage = storage.multi <- *)
  (*     MultiOwned.only_enough_owners *)
  (*       (MultiOwned.SetDailyLimit limit, storage.multi) in *)
  match confirmAndCheck (SetDailyLimit limit, storage) with
  | Confirmations_Needed storage -> no_op, storage
  | Execute storage -> no_op, storage.m_daily_limit <- limit


let%entry resetSpentToday _ storage =
  (* let storage = storage.multi <- *)
  (*     MultiOwned.only_enough_owners *)
  (*       (MultiOwned.ResetSpentToday, storage.multi) in *)
  match confirmAndCheck (ResetSpentToday, storage) with
  | Confirmations_Needed storage -> no_op, storage
  | Execute storage -> no_op, storage.m_spent_today <- 0tz

let%entry deposit _ (s : storage) =
  if Current.amount () = 0tz then Current.failwith ()
  else no_op, s

let%entry kill (dest: UnitContract.instance) storage =
  match confirmAndCheck (Kill dest, storage) with
  | Confirmations_Needed storage -> no_op, storage
  | Execute storage ->
    let trans_all = Contract.call dest (Current.balance ()) () in
    [trans_all], storage

let%entry withdraw (t: transaction) storage =
  onlyowner storage;
  (* execute directly if under limit *)
  let under, storage = underLimit (t.amount, storage) in
  if under then
    let op = Contract.call t.destination t.amount () in
    [op], storage
  else
    match confirmAndCheck (Withdraw t, storage) with
    | Confirmations_Needed storage -> no_op, storage
    | Execute storage ->
      let op = Contract.call t.destination t.amount () in
      [op], storage

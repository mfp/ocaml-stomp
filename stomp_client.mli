type received_msg = {
  msg_id : string;
  msg_headers : (string * string) list;
  msg_body : string
}

type stomp_error =
    Connection_closed
  | Protocol_error of (string * (string * string) list * string)

exception Stomp_error of string * stomp_error

module type S =
sig
  type 'a thread
  type connection
  type transaction
  type message_id

  val connect : Unix.sockaddr -> login:string -> password:string -> connection thread
  val disconnect : connection -> unit thread
  val send : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread
  val send_no_ack : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  val receive_msg : connection -> received_msg thread
  val ack_msg : connection -> ?transaction:transaction ->
    received_msg -> unit thread

  val subscribe : connection -> string -> unit thread
  val unsubscribe : connection -> string -> unit thread

  val transaction_begin : connection -> transaction thread
  val transaction_commit : connection -> transaction -> unit thread
  val transaction_commit_all : connection -> unit thread
  val transaction_abort_all : connection -> unit thread
  val transaction_abort : connection -> transaction -> unit thread
end

module Make : functor (C : Concurrency_monad.CLIENT) ->
  S with type 'a thread = 'a C.t

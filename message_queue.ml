type received_msg = {
  msg_id : string;
  msg_headers : (string * string) list;
  msg_body : string
}

type restartable = Retry | Reconnect | Abort
type connection_error = Access_refused | Connection_refused | Closed

type message_queue_error =
    Connection_error of connection_error
  | Protocol_error of (string * (string * string) list * string)

exception Message_queue_error of restartable * string * message_queue_error

module type BASE =
sig
  type 'a thread
  type connection
  type transaction
  type message_id

  val transaction_begin : connection -> transaction thread
  val transaction_commit : connection -> transaction -> unit thread
  val transaction_commit_all : connection -> unit thread
  val transaction_abort_all : connection -> unit thread
  val transaction_abort : connection -> transaction -> unit thread

  val receive_msg : connection -> received_msg thread
  val ack_msg : connection -> ?transaction:transaction -> received_msg -> unit thread

  val disconnect : connection -> unit thread
end

module type GENERIC =
sig
  include BASE

  val connect : ?login:string -> ?passcode:string -> ?eof_nl:bool ->
    ?headers:(string * string) list -> Unix.sockaddr -> connection thread
  val send : connection -> ?transaction:transaction -> ?persistent:bool ->
    destination:string -> ?headers:(string * string) list -> string -> unit thread
  val send_no_ack : connection -> ?transaction:transaction ->
    destination:string -> ?headers:(string * string) list -> string -> unit thread

  val subscribe : connection -> ?headers:(string * string) list -> string -> unit thread
  val unsubscribe : connection -> ?headers:(string * string) list -> string -> unit thread
end

module type HIGH_LEVEL =
sig
  include BASE

  val connect :
    ?prefetch:int -> login:string -> passcode:string -> Unix.sockaddr ->
    connection thread

  val send : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  val send_no_ack : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  val topic_send : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  val topic_send_no_ack : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  val create_queue : connection -> string -> unit thread
  val subscribe_queue : connection -> string -> unit thread
  val unsubscribe_queue : connection -> string -> unit thread
  val subscribe_topic : connection -> string -> unit thread
  val unsubscribe_topic : connection -> string -> unit thread
end


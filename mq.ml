(** Message queue (MQ): message and error type definitions, module types. *)

(** Type of received messages. *)
type received_msg = {
  msg_id : string;
  msg_destination : string;
  msg_headers : (string * string) list;
  msg_body : string
}

(** {3 Errors } *)

(** Suggested error recovery strategy. *)
type restartable = Retry | Reconnect | Abort

(* Type of connection error. *)
type connection_error = Access_refused | Connection_refused | Closed

type message_queue_error =
    Connection_error of connection_error
  | Protocol_error of (string * (string * string) list * string)

(* Exception raised by MQ client operations. *)
exception Message_queue_error of restartable * string * message_queue_error

(** {3 Module types} *)

(** Base MQ module. *)
module type BASE =
sig
  type 'a thread
  type connection
  type transaction

  val transaction_begin : connection -> transaction thread
  val transaction_commit : connection -> transaction -> unit thread
  val transaction_commit_all : connection -> unit thread
  val transaction_abort_all : connection -> unit thread
  val transaction_abort : connection -> transaction -> unit thread

  val receive_msg : connection -> received_msg thread

  (** Acknowledge the reception of a message. *)
  val ack_msg : connection -> ?transaction:transaction -> received_msg -> unit thread

  (** Acknowledge the reception of a message using its message-id. *)
  val ack : connection -> ?transaction:transaction -> string -> unit thread

  val disconnect : connection -> unit thread
end

(** Generic, low-level MQ module, accepting custom headers for the operations
  * not included in {!BASE}. *)
module type GENERIC =
sig
  include BASE

  val connect : ?login:string -> ?passcode:string -> ?eof_nl:bool ->
    ?headers:(string * string) list -> Unix.sockaddr -> connection thread
  val send : connection -> ?transaction:transaction -> ?persistent:bool ->
    destination:string -> ?headers:(string * string) list -> string -> unit thread
  val send_no_ack : connection -> ?transaction:transaction -> ?persistent:bool ->
    destination:string -> ?headers:(string * string) list -> string -> unit thread

  val subscribe : connection -> ?headers:(string * string) list -> string -> unit thread
  val unsubscribe : connection -> ?headers:(string * string) list -> string -> unit thread
end

(** Higher-level message queue, with queue and topic abstractions. *)
module type HIGH_LEVEL =
sig
  include BASE

  val connect :
    ?prefetch:int -> login:string -> passcode:string -> Unix.sockaddr ->
    connection thread

  (** Send and wait for ACK. *)
  val send : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  (** Send without waiting for confirmation. *)
  val send_no_ack : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  (** Send to a topic and wait for ACK *)
  val topic_send : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  (** Send to a topic without waiting for confirmation. *)
  val topic_send_no_ack : connection -> ?transaction:transaction ->
    destination:string -> string -> unit thread

  (** [create queue conn name] creates a persistent queue named [name].
    * Messages sent to will persist. *)
  val create_queue : connection -> string -> unit thread
  val subscribe_queue : connection -> ?auto_delete:bool -> string -> unit thread
  val unsubscribe_queue : connection -> string -> unit thread
  val subscribe_topic : connection -> string -> unit thread
  val unsubscribe_topic : connection -> string -> unit thread
end

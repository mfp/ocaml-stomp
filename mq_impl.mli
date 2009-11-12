(** High-level, object-oriented message queue client implementation built on
  * top of {!Mq.HIGH_LEVEL}. The OO MQ will retry operations on error and
  * reconnect if needed. Previous subscriptions are recovered on reconnection.
  * *)
module Make :
  functor (C : Mq_concurrency.THREAD) ->
  functor (M : Mq.HIGH_LEVEL with type 'a thread = 'a C.t) ->
  sig
    class virtual ['a] mq :
      object
        method virtual ack : ?transaction:'a -> string -> unit M.thread
        method virtual ack_msg :
          ?transaction:'a -> Mq.received_msg -> unit M.thread
        method virtual create_queue : string -> unit M.thread
        method virtual disconnect : unit M.thread
        method virtual receive_msg : Mq.received_msg M.thread
        method virtual reconnect : unit M.thread
        method virtual send :
          ?transaction:'a ->
          destination:string -> string -> unit M.thread
        method virtual send_no_ack :
          ?transaction:'a ->
          destination:string -> string -> unit M.thread
        method virtual subscribe_queue :
          ?auto_delete:bool -> string -> unit M.thread
        method virtual subscribe_topic : string -> unit M.thread
        method virtual topic_send :
          ?transaction:'a ->
          destination:string -> string -> unit M.thread
        method virtual topic_send_no_ack : ?transaction:'a ->
          destination:string -> string -> unit M.thread
        method virtual transaction_abort : 'a -> unit M.thread
        method virtual transaction_abort_all : unit M.thread
        method virtual transaction_begin : 'a M.thread
        method virtual transaction_commit : 'a -> unit M.thread
        method virtual transaction_commit_all : unit M.thread
        method virtual unsubscribe_queue : string -> unit M.thread
        method virtual unsubscribe_topic : string -> unit M.thread
      end

    class simple_queue :
      ?prefetch:int ->
      login:string ->
      passcode:string ->
      Unix.sockaddr ->
      object
        inherit [M.transaction] mq

        method ack : ?transaction:M.transaction -> string -> unit M.thread
        method ack_msg :
          ?transaction:M.transaction -> Mq.received_msg -> unit M.thread
        method create_queue : string -> unit M.thread
        method disconnect : unit M.thread
        method receive_msg : Mq.received_msg M.thread
        method reconnect : unit M.thread
        method send :
          ?transaction:M.transaction ->
          destination:string -> string -> unit M.thread
        method send_no_ack :
          ?transaction:M.transaction ->
          destination:string -> string -> unit M.thread
        method subscribe_queue :
          ?auto_delete:bool -> string -> unit M.thread
        method subscribe_topic : string -> unit M.thread
        method topic_send :
          ?transaction:M.transaction ->
          destination:string -> string -> unit M.thread
        method topic_send_no_ack : ?transaction:M.transaction ->
          destination:string -> string -> unit M.thread
        method transaction_abort : M.transaction -> unit M.thread
        method transaction_abort_all : unit M.thread
        method transaction_begin : M.transaction M.thread
        method transaction_commit : M.transaction -> unit M.thread
        method transaction_commit_all : unit M.thread
        method unsubscribe_queue : string -> unit M.thread
        method unsubscribe_topic : string -> unit M.thread
      end

    val make_tcp_message_queue :
      ?prefetch:int ->
      login:string -> passcode:string -> string -> int -> simple_queue

    val make_unix_message_queue :
      ?prefetch:int ->
      login:string -> passcode:string -> string -> simple_queue
  end

open Mq

module Make
  (C : Mq_concurrency.THREAD)
  (M : HIGH_LEVEL with type 'a thread = 'a C.t) =
struct
  open C

  class virtual ['tx] mq =
  object
    method virtual disconnect : unit M.thread
    method virtual reconnect : unit M.thread
    method virtual transaction_begin : 'tx M.thread
    method virtual transaction_commit : 'tx -> unit M.thread
    method virtual transaction_commit_all : unit M.thread
    method virtual transaction_abort : 'tx -> unit M.thread
    method virtual transaction_abort_all : unit M.thread

    method virtual receive_msg : received_msg M.thread
    method virtual ack_msg : ?transaction:'tx -> received_msg -> unit M.thread
    method virtual ack : ?transaction:'tx -> string -> unit M.thread

    method virtual send :
      ?transaction:'tx -> destination:string -> string -> unit M.thread
    method virtual send_no_ack :
      ?transaction:'tx -> destination:string -> string -> unit M.thread

    method virtual topic_send :
      ?transaction:'tx -> destination:string -> string -> unit M.thread
    method virtual topic_send_no_ack :
      ?transaction:'tx -> destination:string -> string -> unit M.thread

    method virtual create_queue : string -> unit M.thread
    method virtual subscribe_queue : ?auto_delete:bool -> string -> unit M.thread
    method virtual unsubscribe_queue : string -> unit M.thread
    method virtual subscribe_topic : string -> unit M.thread
    method virtual unsubscribe_topic : string -> unit M.thread
  end

  module Tset = Set.Make(struct type t = M.transaction let compare = compare end)

  type subscription = Queue of string | Topic of string
  module Sset = Set.Make(struct type t = subscription let compare = compare end)

  class simple_queue ?prefetch ~login ~passcode addr =
  object(self)
    inherit [M.transaction] mq
    val mutable conn = None
    val mutable subs = Sset.empty

    method disconnect = match conn with
        None -> return ()
      | Some c -> conn <- None; M.disconnect c

    method private reopen_conn =
      let do_set_conn () =
        M.connect ?prefetch ~login ~passcode addr >>= fun c ->
          conn <- Some c;
          self#with_conn
            (fun c -> iter_serial
                        (function
                             Queue q -> M.subscribe_queue c q
                           | Topic t -> M.subscribe_topic c t)
                        (Sset.elements subs)) in
      let rec set_conn () =
        catch
          (fun () -> do_set_conn ())
          (function
               Message_queue_error (_, _, Connection_error (Connection_refused | Closed)) ->
                 C.sleep 1. >>= fun () ->
                 set_conn ()
             | e -> fail e)
      in match conn with
          None -> set_conn ()
        | Some c -> self#disconnect >>= fun () -> set_conn ()

    method reconnect = self#reopen_conn

    method private with_conn : 'a. (M.connection -> 'a t) -> 'a t = fun f ->
      let rec doit c =
        catch
          (fun () -> f c)
          (function
               (* FIXME: retry only N times? *)
               Message_queue_error (Retry, _, _) -> doit c
             | Message_queue_error (Reconnect, _, _) ->
                 self#reopen_conn >>= fun () -> self#with_conn f
             | e -> fail e)
      in match conn with
          None -> self#reopen_conn >>= fun () -> self#with_conn f
        | Some c -> doit c

    method transaction_begin = self#with_conn M.transaction_begin
    method transaction_commit tx = self#with_conn (fun c -> M.transaction_commit c tx)
    method transaction_commit_all = self#with_conn M.transaction_commit_all
    method transaction_abort tx = self#with_conn (fun c -> M.transaction_abort c tx)
    method transaction_abort_all = self#with_conn M.transaction_abort_all

    method receive_msg = self#with_conn M.receive_msg

    method ack_msg ?transaction msg =
      self#with_conn (fun c -> M.ack_msg c ?transaction msg)

    method ack ?transaction msgid =
      self#with_conn (fun c -> M.ack c ?transaction msgid)

    method private aux_send f :
        ?transaction:M.transaction -> destination:string -> string -> unit M.thread =
      fun ?transaction ~destination body ->
        self#with_conn (fun c -> f c ?transaction ~destination body)

    method send = self#aux_send M.send
    method send_no_ack = self#aux_send M.send_no_ack
    method topic_send = self#aux_send M.topic_send
    method topic_send_no_ack = self#aux_send M.topic_send_no_ack

    method create_queue s = self#with_conn (fun c -> M.create_queue c s)

    method subscribe_queue ?(auto_delete = false) s =
      self#with_conn (fun c -> M.subscribe_queue ~auto_delete c s) >>= fun () ->
      subs <- Sset.add (Queue s) subs;
      return ()

    method unsubscribe_queue s =
      subs <- Sset.remove (Queue s) subs;
      match conn with
          None -> return ()
        | Some c ->
            (* ignore any errors, since we have already removed it from the
             * set of subscriptions, and won't be resubscribed to on reconn *)
            catch (fun () -> M.unsubscribe_queue c s) (fun _ -> return ())

    method subscribe_topic s =
      self#with_conn (fun c -> M.subscribe_topic c s) >>= fun () ->
      subs <- Sset.add (Topic s) subs;
      return ()

    method unsubscribe_topic s =
      subs <- Sset.remove (Topic s) subs;
      match conn with
          None -> return ()
        | Some c ->
            (* ignore any errors, since we have already removed it from the
             * set of subscriptions, and won't be resubscribed to on reconn *)
            catch (fun () -> M.unsubscribe_topic c s) (fun _ -> return ())
  end

  let make_tcp_message_queue ?prefetch ~login ~passcode addr port =
    new simple_queue ?prefetch ~login ~passcode
      (Unix.ADDR_INET (Unix.inet_addr_of_string addr, port))

  let make_unix_message_queue ?prefetch ~login ~passcode path =
    new simple_queue ?prefetch ~login ~passcode (Unix.ADDR_UNIX path)
end

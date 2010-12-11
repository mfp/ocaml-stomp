(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)

(** Concurrency monads over which the message queue clients are functorized. *)

module type THREAD =
sig
  type 'a t
  val return : 'a -> 'a t
  val (>>=) : 'a t -> ('a -> 'b t) -> 'b t
  val bind : 'a t -> ('a -> 'b t) -> 'b t
  val catch : (unit -> 'a t) -> (exn -> 'a t) -> 'a t
  val fail : exn -> 'a t
  val sleep : float -> unit t

  val iter_serial : ('a -> unit t) -> 'a list -> unit t

  type in_channel
  type out_channel
  val open_connection : Unix.sockaddr -> (in_channel * out_channel) t
  val output_char : out_channel -> char -> unit t
  val output_string : out_channel -> string -> unit t
  val flush : out_channel -> unit t
  val input_char : in_channel -> char t
  val input : in_channel -> string -> int -> int -> int t
  val input_line : in_channel -> string t
  val really_input : in_channel -> string -> int -> int -> unit t
  val close_in : in_channel -> unit t
  val close_out : out_channel -> unit t
  val close_in_noerr : in_channel -> unit t
  val close_out_noerr : out_channel -> unit t

  type 'a pool
  val create_pool : int -> ?check:('a -> bool) -> (unit -> 'a t) -> 'a pool
  val use : 'a pool -> ('a -> 'b t) -> 'b t
end

module Posix_thread : THREAD
  with type 'a t = 'a
   and type in_channel = Pervasives.in_channel
   and type out_channel = Pervasives.out_channel
= struct
  type 'a t = 'a
  let return x = x
  let (>>=) v f =  f v
  let bind = (>>=)
  let fail = raise
  let iter_serial = List.iter
  let sleep = Thread.delay

  include Pervasives
  let open_connection = Unix.open_connection
  let catch f rescue = try f () with e -> rescue e

  type 'a pool = {
    create : unit -> 'a;
    check : 'a -> bool;
    max : int;
    mutable count : int;
    list : 'a Queue.t;
    mutex : Mutex.t;
    condition : Condition.t;
  }

  (* FIXME: POSIX thread pools totally untested *)
  let create_pool n ?(check = fun _ -> true) f =
    {
      create = f;
      check = check;
      max = n;
      count = 0;
      list = Queue.create ();
      mutex = Mutex.create ();
      condition = Condition.create ();
    }

  let locked f p =
    Mutex.lock p.mutex;
    Std.finally (fun () -> Mutex.unlock p.mutex) f p

  let acquire p =
    locked
      (fun p ->
         while Queue.is_empty p.list && p.count >= p.max do
           Condition.wait p.condition p.mutex
         done;
         try
           Queue.take p.list
         with Queue.Empty ->
           p.count <- p.count + 1;
           p.create ())
      p

  let do_release c p =
    Queue.push c p.list;
    Condition.signal p.condition

  let release p c = locked (do_release c) p

  let checked_release p c =
    locked
      (fun p ->
         if p.check c then do_release c p
         else begin
           p.count <- p.count - 1;
           Condition.signal p.condition
         end)
      p

  let use p f =
    let c = acquire p in
      try
        let r = f c in
          release p c;
          r
      with e -> checked_release p c; raise e
end

module Green_thread : THREAD
  with type 'a t = 'a Lwt.t
   and type in_channel = Lwt_chan.in_channel
   and type out_channel = Lwt_chan.out_channel
= struct
  include Lwt_util
  include Lwt_chan
  include Lwt

  let sleep = Lwt_unix.sleep

  let close_in_noerr ch = catch (fun () -> close_in ch) (fun _ -> return ())

  type 'a pool = 'a Lwt_pool.t

  let create_pool n ?(check = fun _ -> true) f =
    Lwt_pool.create n ~check:(fun x f -> f (check x)) f

  let use = Lwt_pool.use

  let close_out oc = flush oc >>= fun () -> close_out oc
  let close_out_noerr ch = catch (fun () -> close_out ch) (fun _ -> return ())
end


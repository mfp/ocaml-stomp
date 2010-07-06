(* Copyright (c) 2009 Mauricio Fernández <mfp@acm.org> *)
open Arg
open Printf
open ExtString
open ExtList

module S = Mq_stomp_client.Make_generic(Mq_concurrency.Posix_thread)

let () = Random.self_init ()

let port = ref 61613
let address = ref "127.0.0.1"
let num_msgs = ref 0
let queue = ref (sprintf "/queue/test-%d" (Random.int 100000000))
let login = ref None
let passcode = ref None
let num_queues = ref None
let use_nl_eof = ref false
let no_ack = ref false
let payload = ref None
let headers = ref []
let persistent = ref false
let verbose = ref false
let nthreads = ref 1

let msg = "Usage: test_send -n N [options]"

let set_some r x = r := Some x
let set_some_f f r x = r := Some (f x)

let args =
  Arg.align
    [
      "-n", Set_int num_msgs, sprintf "N Send N messages (default: %d)" !num_msgs;
      "-a", Set_string address, sprintf "ADDRESS Address (default: %s)" !address;
      "-p", Set_int port, sprintf "PORT Port (default: %d)" !port;
      "-q", Set_string queue, sprintf "QUEUE Send to queue QUEUE (default: %s)" !queue;
      "--persistent", Set persistent, " Set persistent: true.";
      "--queues", String (set_some_f int_of_string num_queues), "N Send to N queues.";
      "--login", String (set_some login), "LOGIN Use the given login (default: none).";
      "--passcode", String (set_some passcode), "PASSCODE Use the given passcode (default: none).";
      "--newline", Set use_nl_eof, " Use \\0\\n to signal end of frame (default: no).";
      "--async", Set no_ack, " Send without waiting for receipt.";
      "--concurrency", Set_int nthreads, "N Concurrency factor.";
      "--payload", Int (fun n -> payload := Some n), "N Use payload of length N.";
      "--header", String (fun h -> headers := h :: !headers),
         "HEADER Use the supplied custom header.";
      "--verbose", Set verbose, " Verbose mode.";
    ]

let () =
  Arg.parse args ignore msg;
  if !num_msgs <= 0 then begin
    Arg.usage args msg;
    exit 1;
  end;
  let gen_payload = match !payload with
      None -> string_of_int
    | Some n ->
        let s = String.init n (fun _ -> Char.chr (Random.int 256)) in
          fun _ -> s in
  let queue_name i = match !num_queues with
      None -> !queue
    | Some n -> String.concat "-" [!queue; string_of_int (i mod n)] in
  let cnt = ref 0 in
  let headers =
    List.filter_map
      (fun h -> try Some (String.split h ":") with _ -> None)
      !headers in
  let persistent = !persistent in

  let send_last c =
    (* send the last one with receipt, so we know the server has read all the
     * other SENDs *)
    S.send c ~headers ~destination:(queue_name !cnt) (gen_payload !cnt);
    incr cnt in

  let t0 = Unix.gettimeofday () in
  let print_rate () =
    let dt = Unix.gettimeofday () -. t0 in
      printf "\n\nSent %8.1f messages/second.\n" (float !cnt /. dt) in

  let finish = ref false in
  let run n =
    let c = S.connect ?login:!login ?passcode:!passcode ~eof_nl:!use_nl_eof
              (Unix.ADDR_INET (Unix.inet_addr_of_string !address, !port))
    in try
      for i = 1 to n do
        if !verbose && !cnt mod 11 = 0 then printf "%d      \r%!" !cnt;
        if !no_ack then
          S.send_no_ack c
            ~persistent ~headers ~destination:(queue_name i) (gen_payload i)
        else
          S.send c
            ~persistent ~headers ~destination:(queue_name i) (gen_payload i);
        incr cnt;
        if !finish then raise Exit;
      done
    with Exit -> send_last c;
                 S.disconnect c
  in
    Sys.set_signal Sys.sigint
      (Sys.Signal_handle
         (fun _ ->
            finish := true;
            print_endline
              "\nSending last message synchronously. Press CTRL-C again to exit.";
            Sys.set_signal Sys.sigint
              (Sys.Signal_handle (fun _ -> print_rate (); exit 1))));
    begin match !num_queues with
        None -> printf "Sending to %s\n" !queue
      | Some n -> printf "Sending to at most %d queues of prefix %s-\n" n !queue
    end;
    begin match !nthreads with
        n when n <= 1 -> run !num_msgs
      | n ->
          let ts = List.init n (fun _ -> Thread.create run (!num_msgs / n)) in
            List.iter Thread.join ts
    end;
    print_rate ();

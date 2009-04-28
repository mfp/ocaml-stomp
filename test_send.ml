open Arg
open Printf

module S = Stomp_client.Make(Concurrency_monad.Posix_thread_client)

let () = Random.self_init ()

let port = ref 61613
let address = ref "127.0.0.1"
let num_msgs = ref 10000
let queue = ref (sprintf "/queue/test-%d" (Random.int 100000000))
let login = ref None
let passcode = ref None
let num_queues = ref None
let use_nl_eof = ref false

let msg = "Usage: test [options]"

let set_some r x = r := Some x
let set_some_f f r x = r := Some (f x)

let args =
  Arg.align
    [
      "-p", Set_int port, sprintf "PORT Port (default: %d)" !port;
      "-a", Set_string address, sprintf "ADDRESS Address (default: %s-0)" !address;
      "-n", Set_int num_msgs, sprintf "N Send N messages (default: %d)" !num_msgs;
      "-q", Set_string queue, sprintf "QUEUE Send to queue QUEUE (default: %s)" !queue;
      "--queues", String (set_some_f int_of_string num_queues), "N Send to N queues.";
      "--login", String (set_some login), "LOGIN Use the given login (default: none).";
      "--passcode", String (set_some passcode), "PASSCODE Use the given passcode (default: none).";
      "--newline", Set use_nl_eof, " Use \\0\\n to signal end of frame (default: no).";
    ]

let () =
  Arg.parse args ignore msg;
  let c = S.connect ?login:!login ?passcode:!passcode ~eof_nl:!use_nl_eof
            (Unix.ADDR_INET (Unix.inet_addr_of_string !address, !port)) in
  let queue_name i = match !num_queues with
      None -> !queue
    | Some n -> String.concat "-" [!queue; string_of_int (i mod n)]
  in
    begin match !num_queues with
        None -> printf "Sending to %s\n" !queue
      | Some n -> printf "Sending to %d queues of prefix %s-\n" n !queue
    end;
    for i = 1 to !num_msgs do
      printf "\r%d%!" i;
      S.send_no_ack c (queue_name i) (string_of_int i)
    done;
    print_newline ();
    S.disconnect c

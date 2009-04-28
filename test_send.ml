open Arg
open Printf

module S = Stomp_client.Make(Concurrency_monad.Posix_thread_client)

let () = Random.self_init ()

let port = ref 61613
let address = ref "127.0.0.1"
let num_msgs = ref 10000
let queue = ref (sprintf "/queue/test-%d" (Random.int 100000000))
let login = ref ""
let password = ref ""
let num_queues = ref None

let msg = "Usage: test [options]"

let args =
  Arg.align
    [
      "-p", Set_int port, sprintf "PORT Port (default: %d)" !port;
      "-a", Set_string address, sprintf "ADDRESS Address (default: %s-0)" !address;
      "-n", Set_int num_msgs, sprintf "N Send N messages (default: %d)" !num_msgs;
      "-q", Set_string queue, sprintf "QUEUE Send to queue QUEUE (default: %s)" !queue;
      "--queues", String (fun s -> num_queues := Some (int_of_string s)),
        "N Send to N queues.";
    ]

let () = 
  Arg.parse args ignore msg;
  let c = S.connect (Unix.ADDR_INET (Unix.inet_addr_of_string !address, !port))
            ~login:!login ~password:!password in
  let queue_name i = match !num_queues with
      None -> !queue
    | Some n -> String.concat "-" [!queue; string_of_int (i mod n)]
  in
    begin match !num_queues with
        None -> printf "Sending to %s-0\n" !queue
      | Some n -> printf "Sending to %d queues of prefix %s-\n" n !queue
    end;
    for i = 1 to !num_msgs do
      printf "\r%d%!" i;
      S.send_no_ack c (queue_name i) (string_of_int i)
    done;
    S.disconnect c

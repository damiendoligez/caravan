open Core.Std
open Async.Std


module Log : sig
  type t

  val create : unit -> t

  val post : t -> msg:string -> unit

  val dump : t -> string list Deferred.t
end = struct
  type t =
    { r : string Pipe.Reader.t
    ; w : string Pipe.Writer.t
    }

  let create () =
    let r, w = Pipe.create () in
    {r; w}

  let post {w; _} ~msg =
    let timestamp = Time.to_string (Time.now ()) in
    let msg = timestamp ^ " => " ^ msg in
    Pipe.write_without_pushback w msg

  let dump {r; w} =
    Pipe.close w;
    Pipe.to_list r >>| fun msgs ->
    msgs

end

module Test = struct
  module Id = struct
    type t = string
  end

  module Result = struct
    type 'state t =
      { id     : Id.t
      ; time   : Time.Span.t
      ; output : ('state, exn) Result.t
      ; log    : string list
      }
  end

  type 'state t =
    { id       : Id.t
    ; case     : 'state -> log:Log.t -> 'state Deferred.t
    ; children : 'state t list
    }

  type 'state add_children =
       'state t
    -> 'state t list
    -> 'state t

  let add_children ({children; _} as t) ts =
    {t with children = children @ ts}

  let (+) =
    add_children
end


let post_progress = function
  | Ok    _ -> printf "."
  | Error _ -> printf "F"

let reporter ~results_r =
  let report_of_results results =
    let module C = Textutils.Ascii_table.Column in
    let module R = Test.Result in
    let time_span_to_string ts = sprintf "%.2f" (Time.Span.to_float ts) in
    let rows = List.rev results in
    let columns =
      [ C.create_attr
          "Status"
          ( function
          | {R.output = Ok    _; _} -> [`Bright; `White; `Bg `Green], " PASS "
          | {R.output = Error _; _} -> [`Bright; `White; `Bg `Red  ], " FAIL "
          )
      ; C.create "ID"   (fun {R.id   ; _} -> id)
      ; C.create "Time" (fun {R.time ; _} -> time_span_to_string time)
      ; C.create
          "Error"
          ~show:`If_not_empty
          ( function
          | {R.output = Ok    _; _} -> ""
          | {R.output = Error e; _} -> Exn.to_string e
          )
      ; C.create
          "Log"
          ~show:`If_not_empty
          (fun {R.log; _} -> String.concat log ~sep:"\n")
      ]
    in
    Textutils.Ascii_table.to_string
      ~display:Textutils.Ascii_table.Display.tall_box
      ~bars:`Unicode
      ~limit_width_to:200   (* TODO: Should be configurable *)
      columns
      rows
  in
  let rec gather results total_failures =
    Pipe.read results_r >>= function
    | `Eof  ->
        printf "\n\n%!";
        return (results, total_failures)
    | `Ok r ->
        let {Test.Result.output; _} = r in
        post_progress output;
        let total_failures =
          match output with
          | Ok    _ ->      total_failures
          | Error _ -> succ total_failures
        in
        gather (r :: results) total_failures
  in
  gather [] 0 >>= fun (results, total_failures) ->
  print_endline (report_of_results results);
  return total_failures

let runner ~tests ~init_state ~results_w =
  let rec run_parent {Test.id; case; children} ~state:state1 =
    let log = Log.create () in
    let time_started = Time.now () in
    try_with ~extract_exn:true (fun () -> case state1 ~log)
    >>= fun output ->
    let time_finished = Time.now () in
    let time_elapsed = Time.diff time_finished time_started in
    Log.dump log
    >>= fun log ->
    let result = Test.Result.({id; time=time_elapsed; output; log}) in
    Pipe.write_without_pushback results_w result;
    match output with
    | Ok state2 -> run_children ~state:state2 children
    | Error _   -> run_children ~state:state1 children  (* TODO: Skip when parent failed *)
  and run_children tests ~state =
    Deferred.List.iter
      tests
      ~how:`Parallel
      ~f:(run_parent ~state)
  in
  run_children tests ~state:init_state >>| fun () ->
  Pipe.close results_w

let run ~tests ~init_state =
  let results_r, results_w = Pipe.create () in
  don't_wait_for (runner   ~results_w ~tests ~init_state);
                  reporter ~results_r
  >>= fun total_failures ->
  exit total_failures

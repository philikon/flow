(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Core
open ClientEnv
open Utils

module Cmd = ServerCommand
module Rpc = ServerRpc

let get_list_files conn (args:client_check_env): string list =
  let ic, oc = conn in
  Cmd.(stream_request oc LIST_FILES);
  let res = ref [] in
  try
    while true do
      res := (Timeout.input_line ic) :: !res
    done;
    assert false
  with End_of_file -> !res

let print_all ic =
  try
    while true do
      Printf.printf "%s\n" (Timeout.input_line ic);
    done
  with End_of_file -> ()

let expand_path file =
  let path = Path.make file in
  if Path.file_exists path
  then Path.to_string path
  else
    let file = Filename.concat (Sys.getcwd()) file in
    let path = Path.make file in
    if Path.file_exists path
    then Path.to_string path
    else begin
      Printf.printf "File not found\n";
      exit 2
    end

let parse_position_string arg =
  let tpos = Str.split (Str.regexp ":") arg in
  try
    match tpos with
    | [line; char] ->
        int_of_string line, int_of_string char
    | _ -> raise Exit
  with _ ->
    Printf.eprintf "Invalid position\n";
    raise Exit_status.(Exit_with Input_error)

let main args =
  let mode_s = ClientEnv.mode_to_string args.mode in
  HackEventLogger.client_set_from args.from;
  HackEventLogger.client_set_mode mode_s;

  HackEventLogger.client_check ();

  let conn = ClientConnect.connect { ClientConnect.
    root = args.root;
    autostart = args.autostart;
    retries = Some args.retries;
    retry_if_init = args.retry_if_init;
    expiry = args.timeout;
    no_load = args.no_load;
    to_ide = false;
    ai_mode = args.ai_mode;
  } in
  let exit_status =
    match args.mode with
    | MODE_LIST_FILES ->
      let infol = get_list_files conn args in
      List.iter infol (Printf.printf "%s\n");
      Exit_status.Ok
    | MODE_LIST_MODES ->
      let ic, oc = conn in
      Cmd.(stream_request oc LIST_MODES);
      begin try
        while true do print_endline (Timeout.input_line ic) done;
      with End_of_file -> () end;
      Exit_status.Ok
    | MODE_COLORING file ->
      let file_input = match file with
        | "-" ->
          let content = Sys_utils.read_stdin_to_string () in
          ServerUtils.FileContent content
        | _ ->
          let file = expand_path file in
          ServerUtils.FileName file
      in
      let pos_level_l = Cmd.rpc conn @@ Rpc.COVERAGE_LEVELS file_input in
      ClientColorFile.go file_input args.output_json pos_level_l;
      Exit_status.Ok
    | MODE_COVERAGE file ->
      let counts_opt =
        Cmd.rpc conn @@ Rpc.COVERAGE_COUNTS (expand_path file) in
      ClientCoverageMetric.go ~json:args.output_json counts_opt;
      Exit_status.Ok
    | MODE_FIND_CLASS_REFS name ->
      let results =
        Cmd.rpc conn @@ Rpc.FIND_REFS (FindRefsService.Class name) in
      ClientFindRefs.go results args.output_json;
      Exit_status.Ok
    | MODE_FIND_REFS name ->
      let pieces = Str.split (Str.regexp "::") name in
      let action =
        try
          match pieces with
          | class_name :: method_name :: _ ->
              FindRefsService.Method (class_name, method_name)
          | method_name :: _ -> FindRefsService.Function method_name
          | _ -> raise Exit
        with _ ->
          Printf.eprintf "Invalid input\n";
          raise Exit_status.(Exit_with Input_error)
      in
      let results = Cmd.rpc conn @@ Rpc.FIND_REFS action in
      ClientFindRefs.go results args.output_json;
      Exit_status.Ok
    | MODE_DUMP_SYMBOL_INFO files ->
      ClientSymbolInfo.go conn files expand_path;
      Exit_status.Ok
    | MODE_DUMP_AI_INFO files ->
      ClientAiInfo.go conn files expand_path;
      Exit_status.Ok
    | MODE_REFACTOR (ref_mode, before, after) ->
      ClientRefactor.go conn args ref_mode before after;
      Exit_status.Ok
    | MODE_IDENTIFY_FUNCTION arg ->
      let line, char = parse_position_string arg in
      let content = Sys_utils.read_stdin_to_string () in
      let result =
        Cmd.rpc conn @@ Rpc.IDENTIFY_FUNCTION (content, line, char) in
      let result = match result with
        | Some result -> Utils.strip_ns result.IdentifySymbolService.name
        | _ -> ""
      in
      print_endline result;
      Exit_status.Ok
    | MODE_TYPE_AT_POS arg ->
      let tpos = Str.split (Str.regexp ":") arg in
      let fn, line, char =
        try
          match tpos with
          | [filename; line; char] ->
              let fn = expand_path filename in
              ServerUtils.FileName fn, int_of_string line, int_of_string char
          | [line; char] ->
              let content = Sys_utils.read_stdin_to_string () in
              ServerUtils.FileContent content,
              int_of_string line,
              int_of_string char
          | _ -> raise Exit
        with _ ->
          Printf.eprintf "Invalid position\n";
          raise Exit_status.(Exit_with Input_error)
      in
      let pos, ty = Cmd.rpc conn @@ Rpc.INFER_TYPE (fn, line, char) in
      ClientTypeAtPos.go pos ty args.output_json;
      Exit_status.Ok
    | MODE_ARGUMENT_INFO arg ->
      let tpos = Str.split (Str.regexp ":") arg in
      let line, char =
        try
          match tpos with
          | [line; char] ->
              int_of_string line, int_of_string char
          | _ -> raise Exit
        with _ ->
          Printf.eprintf "Invalid position\n";
          raise Exit_status.(Exit_with Input_error)
      in
      let content = Sys_utils.read_stdin_to_string () in
      let results =
        Cmd.rpc conn @@ Rpc.ARGUMENT_INFO (content, line, char) in
      ClientArgumentInfo.go results args.output_json;
      Exit_status.Ok
    | MODE_AUTO_COMPLETE ->
      let content = Sys_utils.read_stdin_to_string () in
      let results = Cmd.rpc conn @@ Rpc.AUTOCOMPLETE content in
      ClientAutocomplete.go results args.output_json;
      Exit_status.Ok
    | MODE_OUTLINE ->
      let content = Sys_utils.read_stdin_to_string () in
      let results = Cmd.rpc conn @@ Rpc.OUTLINE content in
      ClientOutline.go results args.output_json;
      Exit_status.Ok
    | MODE_METHOD_JUMP_CHILDREN class_ ->
      let results = Cmd.rpc conn @@ Rpc.METHOD_JUMP (class_, true) in
      ClientMethodJumps.go results true args.output_json;
      Exit_status.Ok
    | MODE_METHOD_JUMP_ANCESTORS class_ ->
      let results = Cmd.rpc conn @@ Rpc.METHOD_JUMP (class_, false) in
      ClientMethodJumps.go results false args.output_json;
      Exit_status.Ok
    | MODE_STATUS ->
      let error_list = Cmd.rpc conn Rpc.STATUS in
      if args.output_json || args.from <> "" || error_list = []
      then begin
        (* this should really go to stdout but we need to adapt the various
         * IDE plugins first *)
        let oc = if args.output_json then stderr else stdout in
        ServerError.print_errorl args.output_json error_list oc
      end else List.iter error_list ClientCheckStatus.print_error_color;
      if error_list = [] then Exit_status.Ok else Exit_status.Type_error
    | MODE_SHOW classname ->
      let ic, oc = conn in
      Cmd.(stream_request oc (SHOW classname));
      print_all ic;
      Exit_status.Ok
    | MODE_SEARCH (query, type_) ->
      let results = Cmd.rpc conn @@ Rpc.SEARCH (query, type_) in
      ClientSearch.go results args.output_json;
      Exit_status.Ok
    | MODE_LINT fnl ->
      let fnl = List.fold_left fnl ~f:begin fun acc fn ->
        match Sys_utils.realpath fn with
        | Some path -> path :: acc
        | None ->
            prerr_endlinef "Could not find file '%s'" fn;
            acc
      end ~init:[] in
      let results = Cmd.rpc conn @@ Rpc.LINT fnl in
      ClientLint.go results args.output_json;
      Exit_status.Ok
    | MODE_LINT_ALL code ->
      let results = Cmd.rpc conn @@ Rpc.LINT_ALL code in
      ClientLint.go results args.output_json;
      Exit_status.Ok
    | MODE_CREATE_CHECKPOINT x ->
      Cmd.rpc conn @@ Rpc.CREATE_CHECKPOINT x;
      Exit_status.Ok
    | MODE_RETRIEVE_CHECKPOINT x ->
      let results = Cmd.rpc conn @@ Rpc.RETRIEVE_CHECKPOINT x in
      begin
        match results with
        | Some results ->
            List.iter results print_endline;
            Exit_status.Ok
        | None ->
            Exit_status.Checkpoint_error
      end
    | MODE_DELETE_CHECKPOINT x ->
      if Cmd.rpc conn @@ Rpc.DELETE_CHECKPOINT x then
        Exit_status.Ok
      else
        Exit_status.Checkpoint_error
    | MODE_STATS ->
      let stats = Cmd.rpc conn @@ Rpc.STATS in
      print_string @@ Hh_json.json_to_multiline (Stats.to_json stats);
      Exit_status.Ok
    | MODE_FIND_LVAR_REFS arg ->
      let line, char = parse_position_string arg in
      let content = Sys_utils.read_stdin_to_string () in
      let results =
        Cmd.rpc conn @@ Rpc.FIND_LVAR_REFS (content, line, char) in
      ClientFindLocals.go results args.output_json;
      Exit_status.Ok
    | MODE_GET_METHOD_NAME arg ->
      let line, char = parse_position_string arg in
      let content = Sys_utils.read_stdin_to_string () in
      let result =
        Cmd.rpc conn @@ Rpc.IDENTIFY_FUNCTION (content, line, char) in
      ClientGetMethodName.go result args.output_json;
      Exit_status.Ok
    | MODE_FORMAT (from, to_) ->
      let content = Sys_utils.read_stdin_to_string () in
      let result =
        Cmd.rpc conn @@ Rpc.FORMAT (content, from, to_) in
      ClientFormat.go result args.output_json;
      Exit_status.Ok
  in
  HackEventLogger.client_check_finish exit_status;
  exit_status

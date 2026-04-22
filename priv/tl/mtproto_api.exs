%{
  "constructors" => [
    %{
      "id" => nil,
      "params" => [%{"name" => nil, "type" => "?"}],
      "predicate" => "int",
      "type" => "Int"
    },
    %{
      "id" => nil,
      "params" => [%{"name" => nil, "type" => "?"}],
      "predicate" => "long",
      "type" => "Long"
    },
    %{
      "id" => nil,
      "params" => [%{"name" => nil, "type" => "?"}],
      "predicate" => "double",
      "type" => "Double"
    },
    %{
      "id" => nil,
      "params" => [%{"name" => nil, "type" => "?"}],
      "predicate" => "string",
      "type" => "String"
    },
    %{
      "id" => nil,
      "params" => [],
      "predicate" => "dummyHttpWait",
      "type" => "HttpWait"
    },
    %{
      "id" => nil,
      "params" => [
        %{"name" => nil, "type" => "#"},
        %{"name" => nil, "type" => "[ t ]"}
      ],
      "predicate" => "vector",
      "type" => "Vector t"
    },
    %{
      "id" => nil,
      "params" => [%{"name" => nil, "type" => "4*[ int ]"}],
      "predicate" => "int128",
      "type" => "Int128"
    },
    %{
      "id" => nil,
      "params" => [%{"name" => nil, "type" => "8*[ int ]"}],
      "predicate" => "int256",
      "type" => "Int256"
    },
    %{
      "id" => "85337187",
      "params" => [
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "pq", "type" => "string"},
        %{"name" => "server_public_key_fingerprints", "type" => "Vector<long>"}
      ],
      "predicate" => "resPQ",
      "type" => "ResPQ"
    },
    %{
      "id" => "2851430293",
      "params" => [
        %{"name" => "pq", "type" => "string"},
        %{"name" => "p", "type" => "string"},
        %{"name" => "q", "type" => "string"},
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "new_nonce", "type" => "int256"},
        %{"name" => "dc", "type" => "int"}
      ],
      "predicate" => "p_q_inner_data_dc",
      "type" => "P_Q_inner_data"
    },
    %{
      "id" => "1459478408",
      "params" => [
        %{"name" => "pq", "type" => "string"},
        %{"name" => "p", "type" => "string"},
        %{"name" => "q", "type" => "string"},
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "new_nonce", "type" => "int256"},
        %{"name" => "dc", "type" => "int"},
        %{"name" => "expires_in", "type" => "int"}
      ],
      "predicate" => "p_q_inner_data_temp_dc",
      "type" => "P_Q_inner_data"
    },
    %{
      "id" => "3504867164",
      "params" => [
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "encrypted_answer", "type" => "string"}
      ],
      "predicate" => "server_DH_params_ok",
      "type" => "Server_DH_Params"
    },
    %{
      "id" => "3045658042",
      "params" => [
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "g", "type" => "int"},
        %{"name" => "dh_prime", "type" => "string"},
        %{"name" => "g_a", "type" => "string"},
        %{"name" => "server_time", "type" => "int"}
      ],
      "predicate" => "server_DH_inner_data",
      "type" => "Server_DH_inner_data"
    },
    %{
      "id" => "1715713620",
      "params" => [
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "retry_id", "type" => "long"},
        %{"name" => "g_b", "type" => "string"}
      ],
      "predicate" => "client_DH_inner_data",
      "type" => "Client_DH_Inner_Data"
    },
    %{
      "id" => "1003222836",
      "params" => [
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "new_nonce_hash1", "type" => "int128"}
      ],
      "predicate" => "dh_gen_ok",
      "type" => "Set_client_DH_params_answer"
    },
    %{
      "id" => "1188831161",
      "params" => [
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "new_nonce_hash2", "type" => "int128"}
      ],
      "predicate" => "dh_gen_retry",
      "type" => "Set_client_DH_params_answer"
    },
    %{
      "id" => "2795351554",
      "params" => [
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "new_nonce_hash3", "type" => "int128"}
      ],
      "predicate" => "dh_gen_fail",
      "type" => "Set_client_DH_params_answer"
    },
    %{
      "id" => "1973679973",
      "params" => [
        %{"name" => "nonce", "type" => "long"},
        %{"name" => "temp_auth_key_id", "type" => "long"},
        %{"name" => "perm_auth_key_id", "type" => "long"},
        %{"name" => "temp_session_id", "type" => "long"},
        %{"name" => "expires_at", "type" => "int"}
      ],
      "predicate" => "bind_auth_key_inner",
      "type" => "BindAuthKeyInner"
    },
    %{
      "id" => "558156313",
      "params" => [
        %{"name" => "error_code", "type" => "int"},
        %{"name" => "error_message", "type" => "string"}
      ],
      "predicate" => "rpc_error",
      "type" => "RpcError"
    },
    %{
      "id" => "1579864942",
      "params" => [],
      "predicate" => "rpc_answer_unknown",
      "type" => "RpcDropAnswer"
    },
    %{
      "id" => "3447252358",
      "params" => [],
      "predicate" => "rpc_answer_dropped_running",
      "type" => "RpcDropAnswer"
    },
    %{
      "id" => "2755319991",
      "params" => [
        %{"name" => "msg_id", "type" => "long"},
        %{"name" => "seq_no", "type" => "int"},
        %{"name" => "bytes", "type" => "int"}
      ],
      "predicate" => "rpc_answer_dropped",
      "type" => "RpcDropAnswer"
    },
    %{
      "id" => "155834844",
      "params" => [
        %{"name" => "valid_since", "type" => "int"},
        %{"name" => "valid_until", "type" => "int"},
        %{"name" => "salt", "type" => "long"}
      ],
      "predicate" => "future_salt",
      "type" => "FutureSalt"
    },
    %{
      "id" => "2924480661",
      "params" => [
        %{"name" => "req_msg_id", "type" => "long"},
        %{"name" => "now", "type" => "int"},
        %{"name" => "salts", "type" => "vector<future_salt>"}
      ],
      "predicate" => "future_salts",
      "type" => "FutureSalts"
    },
    %{
      "id" => "880243653",
      "params" => [
        %{"name" => "msg_id", "type" => "long"},
        %{"name" => "ping_id", "type" => "long"}
      ],
      "predicate" => "pong",
      "type" => "Pong"
    },
    %{
      "id" => "2663516424",
      "params" => [
        %{"name" => "first_msg_id", "type" => "long"},
        %{"name" => "unique_id", "type" => "long"},
        %{"name" => "server_salt", "type" => "long"}
      ],
      "predicate" => "new_session_created",
      "type" => "NewSession"
    },
    %{
      "id" => "812830625",
      "params" => [%{"name" => "packed_data", "type" => "string"}],
      "predicate" => "gzip_packed",
      "type" => "GzipPacked"
    },
    %{
      "id" => "1658238041",
      "params" => [%{"name" => "msg_ids", "type" => "Vector<long>"}],
      "predicate" => "msgs_ack",
      "type" => "MsgsAck"
    },
    %{
      "id" => "2817521681",
      "params" => [
        %{"name" => "bad_msg_id", "type" => "long"},
        %{"name" => "bad_msg_seqno", "type" => "int"},
        %{"name" => "error_code", "type" => "int"}
      ],
      "predicate" => "bad_msg_notification",
      "type" => "BadMsgNotification"
    },
    %{
      "id" => "3987424379",
      "params" => [
        %{"name" => "bad_msg_id", "type" => "long"},
        %{"name" => "bad_msg_seqno", "type" => "int"},
        %{"name" => "error_code", "type" => "int"},
        %{"name" => "new_server_salt", "type" => "long"}
      ],
      "predicate" => "bad_server_salt",
      "type" => "BadMsgNotification"
    },
    %{
      "id" => "2105940488",
      "params" => [%{"name" => "msg_ids", "type" => "Vector<long>"}],
      "predicate" => "msg_resend_req",
      "type" => "MsgResendReq"
    },
    %{
      "id" => "3664378706",
      "params" => [%{"name" => "msg_ids", "type" => "Vector<long>"}],
      "predicate" => "msgs_state_req",
      "type" => "MsgsStateReq"
    },
    %{
      "id" => "81704317",
      "params" => [
        %{"name" => "req_msg_id", "type" => "long"},
        %{"name" => "info", "type" => "string"}
      ],
      "predicate" => "msgs_state_info",
      "type" => "MsgsStateInfo"
    },
    %{
      "id" => "2361446705",
      "params" => [
        %{"name" => "msg_ids", "type" => "Vector<long>"},
        %{"name" => "info", "type" => "string"}
      ],
      "predicate" => "msgs_all_info",
      "type" => "MsgsAllInfo"
    },
    %{
      "id" => "661470918",
      "params" => [
        %{"name" => "msg_id", "type" => "long"},
        %{"name" => "answer_msg_id", "type" => "long"},
        %{"name" => "bytes", "type" => "int"},
        %{"name" => "status", "type" => "int"}
      ],
      "predicate" => "msg_detailed_info",
      "type" => "MsgDetailedInfo"
    },
    %{
      "id" => "2157819615",
      "params" => [
        %{"name" => "answer_msg_id", "type" => "long"},
        %{"name" => "bytes", "type" => "int"},
        %{"name" => "status", "type" => "int"}
      ],
      "predicate" => "msg_new_detailed_info",
      "type" => "MsgDetailedInfo"
    },
    %{
      "id" => nil,
      "params" => [
        %{"name" => "n", "type" => "string"},
        %{"name" => "e", "type" => "string"}
      ],
      "predicate" => "rsa_public_key",
      "type" => "RSAPublicKey"
    },
    %{
      "id" => "4133544404",
      "params" => [],
      "predicate" => "destroy_auth_key_ok",
      "type" => "DestroyAuthKeyRes"
    },
    %{
      "id" => "178201177",
      "params" => [],
      "predicate" => "destroy_auth_key_none",
      "type" => "DestroyAuthKeyRes"
    },
    %{
      "id" => "3926956819",
      "params" => [],
      "predicate" => "destroy_auth_key_fail",
      "type" => "DestroyAuthKeyRes"
    }
  ],
  "methods" => [
    %{
      "id" => "3195965169",
      "method" => "req_pq_multi",
      "params" => [%{"name" => "nonce", "type" => "int128"}],
      "type" => "ResPQ"
    },
    %{
      "id" => "3608339646",
      "method" => "req_DH_params",
      "params" => [
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "p", "type" => "string"},
        %{"name" => "q", "type" => "string"},
        %{"name" => "public_key_fingerprint", "type" => "long"},
        %{"name" => "encrypted_data", "type" => "string"}
      ],
      "type" => "Server_DH_Params"
    },
    %{
      "id" => "4110704415",
      "method" => "set_client_DH_params",
      "params" => [
        %{"name" => "nonce", "type" => "int128"},
        %{"name" => "server_nonce", "type" => "int128"},
        %{"name" => "encrypted_data", "type" => "string"}
      ],
      "type" => "Set_client_DH_params_answer"
    },
    %{
      "id" => "1491380032",
      "method" => "rpc_drop_answer",
      "params" => [%{"name" => "req_msg_id", "type" => "long"}],
      "type" => "RpcDropAnswer"
    },
    %{
      "id" => "3105996036",
      "method" => "get_future_salts",
      "params" => [%{"name" => "num", "type" => "int"}],
      "type" => "FutureSalts"
    },
    %{
      "id" => "4081220492",
      "method" => "ping_delay_disconnect",
      "params" => [
        %{"name" => "ping_id", "type" => "long"},
        %{"name" => "disconnect_delay", "type" => "int"}
      ],
      "type" => "Pong"
    },
    %{
      "id" => "2459514271",
      "method" => "http_wait",
      "params" => [
        %{"name" => "max_delay", "type" => "int"},
        %{"name" => "wait_after", "type" => "int"},
        %{"name" => "max_wait", "type" => "int"}
      ],
      "type" => "HttpWait"
    },
    %{
      "id" => "3510849888",
      "method" => "destroy_auth_key",
      "params" => [],
      "type" => "DestroyAuthKeyRes"
    }
  ]
}

defmodule MTProto.SessionDataTest do
  use ExUnit.Case, async: true

  alias MTProto.SessionData

  test "round-trips durable session data through maps" do
    session_data =
      SessionData.new!(
        auth_key_data: MTProto.AuthExchangeSample.expected_auth_key(),
        server_salt: MTProto.AuthExchangeSample.expected_server_salt(),
        time_offset: MTProto.AuthExchangeSample.expected_time_offset(),
        dc_id: 2
      )

    assert {:ok, ^session_data} =
             session_data
             |> SessionData.to_map()
             |> SessionData.from_map()
  end

  test "accepts string-keyed maps" do
    map = %{
      "version" => 1,
      "auth_key_data" => MTProto.AuthExchangeSample.expected_auth_key(),
      "server_salt" => MTProto.AuthExchangeSample.expected_server_salt(),
      "time_offset" => MTProto.AuthExchangeSample.expected_time_offset(),
      "dc_id" => 4
    }

    assert {:ok,
            %SessionData{
              dc_id: 4,
              auth_key_data: auth_key_data
            }} = SessionData.from_map(map)

    assert auth_key_data == MTProto.AuthExchangeSample.expected_auth_key()
  end
end

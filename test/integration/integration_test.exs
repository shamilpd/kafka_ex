defmodule Kafka.Integration.Test do
  use ExUnit.Case
  @moduletag :integration

  test "Kafka.Server starts on Application start up" do
    pid = Process.whereis(Kafka.Server)
    assert is_pid(pid)
  end

  test "Kafka.Server connects to all supplied brokers" do
    pid = Process.whereis(Kafka.Server)
    {_, _metadata, socket_map} = :sys.get_state(pid)
    assert Enum.sort(Map.keys(socket_map)) == Enum.sort(uris)
  end

  test "Kafka.Server generates metadata on start up" do
    pid = Process.whereis(Kafka.Server)
    {_, metadata, _socket_map} = :sys.get_state(pid)
    refute metadata == %{}

    brokers = Map.values(metadata[:brokers])

    assert Enum.sort(brokers) == Enum.sort(uris)
  end

  test "start_link creates the server and registers it as the module name" do
    {:ok, pid} = Kafka.Server.start_link(uris, :test_server)
    assert pid == Process.whereis(:test_server)
  end

  test "start_link raises an exception when it is provided a bad connection" do
    assert_link_exit(Kafka.ConnectionError, "Error: Cannot connect to any of the broker(s) provided", fn -> Kafka.Server.start_link([{"bad_host", 1000}], :no_host) end)
  end

  test "metadata attempts to connect via one of the exisiting sockets" do
    {:ok, pid} = Kafka.Server.start_link(uris, :one_working_port)
    {_, _metadata, socket_map} = :sys.get_state(pid)
    [_ |rest] = Map.values(socket_map) |> Enum.reverse
    Enum.each(rest, &:gen_tcp.close/1)
    brokers = Kafka.Server.metadata("", :one_working_port)[:brokers] |> Map.values
    assert Enum.sort(brokers) == Enum.sort(uris)
  end

  #produce
  test "produce withiout an acq required returns :ok" do
    assert Kafka.Server.produce("food", 0, "hey") == :ok
  end

  test "produce with ack required returns an ack" do
    {:ok, %{"food" => %{0 => %{error_code: 0, offset: offset}}}} =  Kafka.Server.produce("food", 0, "hey", nil, 1)
    refute offset == nil
  end

  test "produce updates metadata" do
    pid = Process.whereis(Kafka.Server)
    :sys.replace_state(pid, fn({correlation_id, _metadata, socket_map}) -> {correlation_id, %{}, socket_map} end)
    Kafka.Server.produce("food", 0, "hey")
    {_, metadata, _socket_map} = :sys.get_state(pid)
    refute metadata == %{}

    brokers = Map.values(metadata[:brokers])

    assert Enum.sort(brokers) == Enum.sort(uris)
  end

  test "fetch updates metadata" do
    pid = Process.whereis(Kafka.Server)
    :sys.replace_state(pid, fn({correlation_id, _metadata, socket_map}) -> {correlation_id, %{}, socket_map} end)
    Kafka.Server.fetch("food", 0, 0)
    {_, metadata, _socket_map} = :sys.get_state(pid)
    refute metadata == %{}

    brokers = Map.values(metadata[:brokers])

    assert Enum.sort(brokers) == Enum.sort(uris)
  end

  test "fetch works" do
    {:ok, %{"food" => %{0 => %{error_code: 0, offset: offset}}}} =  Kafka.Server.produce("food", 0, "hey foo", nil, 1)
    {:ok, %{"food" => %{0 => %{message_set: message_set}}}} = Kafka.Server.fetch("food", 0, 0)
    message = message_set |> Enum.reverse |> hd

    assert message.value == "hey foo"
    assert message.offset == offset
  end

  test "offset updates metadata" do
    pid = Process.whereis(Kafka.Server)
    :sys.replace_state(pid, fn({correlation_id, _metadata, socket_map}) -> {correlation_id, %{}, socket_map} end)
    Kafka.Server.latest_offset("food", 0)
    {_, metadata, _socket_map} = :sys.get_state(pid)
    refute metadata == %{}

    brokers = Map.values(metadata[:brokers])

    assert Enum.sort(brokers) == Enum.sort(uris)
  end

  def uris do
    Mix.Config.read!("config/config.exs") |> hd |> elem(1) |> hd |> elem(1)
  end

  def assert_link_exit(exception, message, function) when is_function(function) do
    error = assert_link_exit(exception, function)
    is_match = cond do
      is_binary(message) -> Exception.message(error) == message
      Regex.regex?(message) -> Exception.message(error) =~ message
    end
    msg = "Wrong message for #{inspect exception}. " <>
    "Expected #{inspect message}, got #{inspect Exception.message(error)}"
    assert is_match, message: msg
    error
  end

  def assert_link_exit(exception, function) when is_function(function) do
    Process.flag(:trap_exit, true)
    function.()
    error = receive do
      {:EXIT, _, {:function_clause, [{error, :exception, [message], _}|_]}} -> Map.put(error.__struct__, :message, message)
      {:EXIT, _, {:undef, [{module, function, args, _}]}} -> %UndefinedFunctionError{module: module, function: function, arity: length(args)}
      {:EXIT, _, {:function_clause, [{module, function, args, _}|_]}} -> %FunctionClauseError{module: module, function: function, arity: length(args)}
      {:EXIT, _, {error, _}} -> error
    after
      1000 -> :nothing
    end

    if error == :nothing do
      flunk "Expected exception #{inspect exception} but nothing was raised"
    else
      name = error.__struct__
      cond do
        name == exception ->
          error
        true ->
          flunk "Expected exception #{inspect exception} but got #{inspect name} (#{error.__struct__.message(error)})"
      end
    end
    error
  end

end

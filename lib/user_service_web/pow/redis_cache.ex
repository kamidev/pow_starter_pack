defmodule UserServiceWeb.Pow.RedisCache do
  @behaviour Pow.Store.Backend.Base

  alias Pow.Config

  @impl true
  def put(config, record_or_records) do
    ttl = Config.get(config, :ttl) || raise_ttl_error()

    commands =
      record_or_records
      |> List.wrap()
      |> Enum.map(fn {key, value} ->
        config
        |> binary_redis_key(key)
        |> put_command(value, ttl)
      end)

    Redix.noreply_pipeline(UserService.Redix.instance_name(), commands)
  end

  defp put_command(key, value, ttl) do
    value = value |> clean_value() |> :erlang.term_to_binary()
    ["SET", key, value, "PX", ttl]
  end

  # Avoid writing the entire User struct into Redis
  # Must remain a User struct or errors occur from pow
  defp clean_value(%UserService.Users.User{id: id, guid: guid}) do
    %UserService.Users.User{id: id, guid: guid}
  end

  defp clean_value(val), do: val

  @impl true
  def delete(config, key) do
    key =
      config
      |> redis_key(key)
      |> to_binary_redis_key()

    Redix.noreply_command(UserService.Redix.instance_name(), ["DEL", key])
  end

  @impl true
  def get(config, key) do
    key =
      config
      |> redis_key(key)
      |> to_binary_redis_key()

    case Redix.command(UserService.Redix.instance_name(), ["GET", key]) do
      {:ok, nil} -> :not_found
      {:ok, value} -> :erlang.binary_to_term(value)
    end
  end

  @impl true
  @doc """
  Examples:

  iex(47)> UserServiceWeb.Pow.RedisCache.all([ttl: 1800000, namespace: "credentials"], :_)
    # all values

  iex(46)> UserServiceWeb.Pow.RedisCache.all([ttl: 1800000, namespace: "credentials"], ["credentials", :_, :_, "6"])
    [
      {["credentials", "Elixir.UserService.Users.User", "user", "6"],
      %{guid: "0c06d077-4fe0-48b1-b9eb-f9c6e2e6de62", id: 6}}
    ]
  """
  def all(config, match_spec) do
    compiled_match_spec = :ets.match_spec_compile([{{match_spec, :_}, [], [:"$_"]}])

    Stream.resource(
      fn -> do_scan(config, compiled_match_spec, "0") end,
      &stream_scan(config, compiled_match_spec, &1),
      fn _ -> :ok end
    )
    |> Enum.to_list()
  end

  defp stream_scan(_config, _compiled_match_spec, {[], "0"}), do: {:halt, nil}

  defp stream_scan(config, compiled_match_spec, {[], iterator}) do
    result = do_scan(config, compiled_match_spec, iterator)

    stream_scan(config, compiled_match_spec, result)
  end

  defp stream_scan(_config, _compiled_match_spec, {keys, iterator}), do: {keys, {[], iterator}}

  defp do_scan(config, compiled_match_spec, iterator) do
    prefix = to_binary_redis_key([namespace(config)]) <> ":*"

    case Redix.command(UserService.Redix.instance_name(), ["SCAN", iterator, "MATCH", prefix]) do
      {:ok, [iterator, res]} -> {filter_or_load_value(compiled_match_spec, res, config), iterator}
    end
  end

  defp filter_or_load_value(compiled_match_spec, keys, config) do
    keys
    |> Enum.map(&convert_key/1)
    |> Enum.sort()
    |> :ets.match_spec_run(compiled_match_spec)
    |> populate_values(config)
  end

  defp convert_key(key) do
    key =
      key
      |> from_binary_redis_key()
      |> unwrap()

    {key, nil}
  end

  defp unwrap([_app | [_namespace | key]]), do: key

  defp populate_values([], _config), do: []

  defp populate_values(records, config) do
    binary_keys = Enum.map(records, fn {key, nil} -> binary_redis_key(config, key) end)

    case Redix.command(UserService.Redix.instance_name(), ["MGET"] ++ binary_keys) do
      {:ok, values} ->
        values = Enum.map(values, &:erlang.binary_to_term/1)

        records
        |> zip_values(values)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  defp zip_values([{key, nil} | next1], [value | next2]) do
    [{key, value} | zip_values(next1, next2)]
  end

  defp zip_values(_, []), do: []
  defp zip_values([], _), do: []

  defp binary_redis_key(config, key) do
    config
    |> redis_key(key)
    |> to_binary_redis_key()
  end

  defp redis_key(config, key) do
    [namespace(config) | List.wrap(key)]
  end

  defp namespace(config) do
    app_namespace = Application.get_env(:user_service, :redis_namespace)
    pow_namespace = Config.get(config, :namespace, "cache")

    "#{app_namespace}:#{pow_namespace}"
  end

  # This is a human readable string, rather than a binary conversion that comes stock
  defp to_binary_redis_key(key) do
    key
    |> Enum.join(":")
  end

  defp from_binary_redis_key(key) do
    key
    |> String.split(":")
  end

  @spec raise_ttl_error :: no_return
  defp raise_ttl_error,
    do: Config.raise_error("`:ttl` configuration option is required for #{inspect(__MODULE__)}")
end

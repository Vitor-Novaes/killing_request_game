defmodule KillingRequestGame.RedisSession do
  @moduledoc """
  Redis persistent game controller for the Killing Request Game.
  Handles persistence of game state and player data in a single controller.
  """

  @redis_prefix "killing_request_game"
  @game_controller_key "#{@redis_prefix}:controller"

  # Main game controller operations
  def save_game_controller(state) do
    Redix.command(:redix, ["SET", @game_controller_key, Jason.encode!(state), "EX", 86400]) # 24 hours TTL
  end

  def get_game_controller do
    case Redix.command(:redix, ["GET", @game_controller_key]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, data} -> {:ok, Jason.decode!(data)}
      error -> error
    end
  end

  def update_game_controller(updates) do
    case get_game_controller() do
      {:ok, current_state} ->
        new_state = apply_updates(current_state, updates)
        save_game_controller(new_state)
        {:ok, new_state}
      {:error, :not_found} ->
        # Initialize with default state if not found
        default_state = %{
          "players" => %{},
          "requests" => %{},
          "successful_requests" => [],
          "killed_requests" => [],
          "assassin" => nil,
          "logs" => [],
          "clues" => generate_clues(),
          "hints" => %{},
          "phase" => "lobby",
          "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
        new_state = apply_updates(default_state, updates)
        save_game_controller(new_state)
        {:ok, new_state}
      error -> error
    end
  end

  # Player operations
  def add_player(player) do
    update_game_controller(%{
      "players" => fn players ->
        Map.put(players, player["id"], player)
      end
    })
  end

  # Helper function to apply updates that may contain functions
  defp apply_updates(current_state, updates) do
    Enum.reduce(updates, current_state, fn {key, value}, acc ->
      case value do
        func when is_function(func) ->
          current_value = Map.get(acc, key, %{})
          updated_value = func.(current_value)
          Map.put(acc, key, updated_value)
        _ ->
          Map.put(acc, key, value)
      end
    end)
  end

  def remove_player(player_id) do
    update_game_controller(%{
      "players" => fn players ->
        Map.delete(players, player_id)
      end
    })
  end

  def get_players do
    case get_game_controller() do
      {:ok, state} -> state["players"]
      {:error, :not_found} -> %{}
    end
  end

  # Game state operations
  def start_game(assassin_id) do
    update_game_controller(%{
      "assassin" => assassin_id,
      "phase" => "questions",
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  def add_log(log_entry) do
    update_game_controller(%{
      "logs" => fn logs ->
        [log_entry | logs]
      end
    })
  end

  # Statistics
  def increment_stat(stat_name) do
    Redix.command(:redix, ["INCR", "#{@redis_prefix}:stats:#{stat_name}"])
  end

  def get_stat(stat_name) do
    case Redix.command(:redix, ["GET", "#{@redis_prefix}:stats:#{stat_name}"]) do
      {:ok, nil} -> {:ok, 0}
      {:ok, value} -> {:ok, String.to_integer(value)}
      error -> error
    end
  end

  def set_phase(phase) do
    update_game_controller(%{
      "phase" => phase
    })
  end

  # Utility functions
  def reset_game do
    default_state = %{
      "players" => %{},
      "requests" => %{},
      "successful_requests" => [],
      "killed_requests" => [],
      "assassin" => nil,
      "logs" => [],
      "clues" => generate_clues(),
      "hints" => %{},
      "phase" => "lobby",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    save_game_controller(default_state)
    {:ok, default_state}
  end

  def get_game_info do
    case get_game_controller() do
      {:ok, state} ->
        %{
          "player_count" => map_size(state["players"]),
          "phase" => state["phase"],
          "log_count" => length(state["logs"]),
          "created_at" => state["created_at"],
          "updated_at" => state["updated_at"]
        }
      {:error, :not_found} ->
        %{
          "player_count" => 0,
          "phase" => "lobby",
          "log_count" => 0,
          "created_at" => nil,
          "updated_at" => nil
        }
    end
  end

  # Convert Redis data to LiveView format (string keys to atom keys)
  def convert_to_liveview_format(redis_data) do
    %{
      players: convert_players(redis_data["players"]),
      requests: redis_data["requests"],
      assassin: redis_data["assassin"],
      logs: convert_logs(redis_data["logs"]),
      clues: redis_data["clues"],
      hints: redis_data["hints"],
      phase: String.to_atom(redis_data["phase"])
    }
  end

  # Convert LiveView data to Redis format (atom keys to string keys)
  def convert_to_redis_format(liveview_data) do
    %{
      "players" => convert_players_to_redis(liveview_data.players),
      "requests" => liveview_data.requests,
      "assassin" => liveview_data.assassin,
      "logs" => convert_logs_to_redis(liveview_data.logs),
      "clues" => liveview_data.clues,
      "hints" => liveview_data.hints,
      "phase" => Atom.to_string(liveview_data.phase),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # Helper conversion functions
  defp convert_players(players) when is_map(players) do
    Map.new(players, fn {id, player} ->
      {id, %{
        id: player["id"],
        name: player["name"],
        x: player["x"],
        y: player["y"],
        role: player["role"]
      }}
    end)
  end
  defp convert_players(_), do: %{}

  defp convert_logs(logs) when is_list(logs) do
    Enum.map(logs, fn log ->
      %{
        player: log["player"],
        action: log["action"],
        request: log["request"]
      }
    end)
  end
  defp convert_logs(_), do: []

  defp convert_players_to_redis(players) when is_map(players) do
    Map.new(players, fn {id, player} ->
      {id, %{
        "id" => player.id,
        "name" => player.name,
        "x" => player.x,
        "y" => player.y,
        "role" => player.role
      }}
    end)
  end
  defp convert_players_to_redis(_), do: %{}

  defp convert_requests_to_redis(requests) when is_map(requests) do
    Map.new(requests, fn {id, request} ->
      {Integer.to_string(id), %{"status" => request.status}}
    end)
  end
  defp convert_requests_to_redis(_), do: %{}

  defp convert_logs_to_redis(logs) when is_list(logs) do
    Enum.map(logs, fn log ->
      %{
        "player" => log.player,
        "action" => log.action,
        "request" => log.request
      }
    end)
  end
  defp convert_logs_to_redis(_), do: []

  def save_clues(answers) do
    clues = %{
      "q0" => "Quando você era pequeno, qual era o seu sonho de futuro ?", "a0" => answers["a0"],
      "q1" => "Qual seu filme favorito ?", "a1" => answers["a1"],
      "q2" => "Qual sua comida favorita ?", "a2" => answers["a2"],
      "q3" => "Qual sua cor favorita ?", "a3" => answers["a3"],
      "q4" => "Qual seu animal favorito ?", "a4" => answers["a4"],
      "q5" => "Quanto tempo de Dental Office ?", "a5" => answers["a5"],
      "q6" => "Qual seu Hobbie favorito ?", "a6" => answers["a6"],
      "q7" => "Qual seu jogo favorito ?", "a7" => answers["a7"]
    }

    update_game_controller(%{
      "clues" => clues
    })
  end

  def get_clues do
    case get_game_controller() do
      {:ok, state} -> state["clues"]
      {:error, :not_found} -> %{}
    end
  end
  # Request tracking functions
  def increment_successful_requests(player_id) do
    update_game_controller(%{
      "successful_requests" => fn successful_requests ->
        [player_id | successful_requests]
      end
    })
  end

  def increment_killed_requests(player_id) do
    update_game_controller(%{
      "killed_requests" => fn killed_requests ->
        [player_id | killed_requests]
      end
    })
  end

  def get_killed_requests do
    case get_game_controller() do
      {:ok, state} -> state["killed_requests"]
      {:error, :not_found} -> %{}
    end
  end

  def get_successful_requests do
    case get_game_controller() do
      {:ok, state} -> state["successful_requests"]
      {:error, :not_found} -> %{}
    end
  end

  def block_player_request(player_id) do
    # Store blocked request with timestamp and assassin info
    assassin = case get_game_controller() do
      {:ok, state} -> state["assassin"]
      _ -> "unknown"
    end

    blocked_data = Jason.encode!(%{
      "assassin_id" => assassin,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    Redix.command(:redix, ["HSET", "#{@redis_prefix}:blocked_requests", player_id, blocked_data])
    Redix.command(:redix, ["EXPIRE", "#{@redis_prefix}:blocked_requests", 10]) # Expire after 10 seconds
  end

  def get_blocked_requests do
    case Redix.command(:redix, ["HGETALL", "#{@redis_prefix}:blocked_requests"]) do
      {:ok, []} -> {:ok, %{}}
      {:ok, list} ->
        blocked_requests = list
        |> Enum.chunk_every(2)
        |> Map.new(fn [key, value] ->
          case Jason.decode(value) do
            {:ok, data} -> {key, data["assassin_id"]}
            _ -> {key, "unknown"}
          end
        end)
        {:ok, blocked_requests}
      _ -> {:ok, %{}}
    end
  end

  def clear_blocked_request(player_id) do
    Redix.command(:redix, ["HDEL", "#{@redis_prefix}:blocked_requests", player_id])
  end

  defp generate_clues do
    %{
      q0: "Quando você era pequeno, qual era o seu sonho de futuro ?", a0: nil,
      q1: "Qual seu filme favorito ?", a1: nil,
      q2: "Qual sua comida favorita ?", a2: nil,
      q3: "Qual sua cor favorita ?", a3: nil,
      q4: "Qual seu animal favorito ?", a4: nil,
      q5: "Quanto tempo de Dental Office ?", a5: nil,
      q6: "Qual seu Hobbie favorito ?", a6: nil,
      q7: "Qual seu jogo favorito ?", a7: nil,
    }
  end
end

defmodule HomesynckWeb.SyncChannel do
  use HomesynckWeb, :channel
  alias Homesynck.Sync
  alias HomesynckWeb.AuthTokenHelper

  @impl true
  def join(
        "sync:" <> directory_id,
        %{"received_updates" => received_updates} = payload,
        socket
      )
      when is_list(received_updates) do
    if authorized?(directory_id, payload, socket) do
      send_missing_updates(received_updates, directory_id, socket)
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in(
        "push_update",
        %{
          "rank" => _rank,
          "instructions" => _instructions
        } = update_attrs,
        %{topic: "sync:" <> directory_id} = socket
      ) do
    resp =
      with {:ok, directory} <- Sync.get_directory(directory_id),
           {:ok, update} <- Sync.push_update_to_directory(directory, update_attrs) do
        broadcast_updates([update], socket)
        {:ok, %{:update_id => update.id}}
      else
        {:error, :not_found} -> {:error, %{:reason => "directory not found"}}
        {:error, error} -> {:error, %{:reason => inspect(error)}}
      end

    {:reply, resp, socket}
  end

  @impl true
  def handle_in(_, _, socket) do
    {:reply, {:error, %{reason: "wrong params"}}, socket}
  end

  defp authorized?(
         directory_id,
         %{"directory_password" => password},
         %{
           assigns: %{
             user_id: user_id,
             auth_token: auth_token
           }
         },
         socket
       ) do
    with true <- AuthTokenHelper.auth_token_valid?(user_id, auth_token, socket),
         {:ok, %Sync.Directory{}} <- Sync.open_directory(directory_id, user_id, password) do
      true
    else
      _ -> false
    end
  end

  defp authorized?(_, _, _), do: false

  defp send_missing_updates(received_updates, directory_id, socket) do
    with {:ok, directory} <- Sync.get_directory(directory_id),
         [_ | _] = missing_updates <- Sync.get_missing_updates(directory, received_updates) do
      send_updates(missing_updates, socket)
    else
      [] -> {:ok, :none_missing}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp send_updates(updates, socket) do
    updates
    |> build_updates()
    |> (&push(socket, "updates", %{"updates" => &1})).()
  end

  defp broadcast_updates(updates, from_socket) do
    updates
    |> build_updates()
    |> (&broadcast(from_socket, "updates", %{"updates" => &1})).()
  end

  defp build_updates(updates) do
    updates
    |> Enum.map(&%{"rank" => &1.rank, "instructions" => &1.instructions})
  end
end

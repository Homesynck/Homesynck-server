defmodule Homesynck.Auth do
  @moduledoc """
  The Auth context.
  """

  import Ecto.Query, warn: false
  alias Homesynck.Repo

  alias Homesynck.Auth.User

  @doc """
  Returns the list of users.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  def get_user(id) do
    user = Repo.get(User, id)

    case user do
      %User{} -> {:ok, user}
      _ -> {:error, :not_found}
    end
  end

  def get_by(%{"name" => name}) do
    Repo.get_by(User, name: name)
  end

  def get_by(%{"email" => email}) do
    Repo.get_by(User, email: email)
  end

  def authenticate(%{"password" => password} = params) do
    with %User{} = user <- get_by(params),
         {:ok, user} <-
           Argon2.check_pass(user, password, [{:hash_key, :password_hashed}]) do
      {:ok, user.id}
    else
      nil -> {:error, "no user found"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a user.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def register(
        %{
          "register_token" => _register_token,
          "name" => _login,
          "password" => _password
        } = params
      ) do
    if get_by(params) do
      {:error, "name taken"}
    else
      case create_user(params) do
        {:ok, user} ->
          {:ok, user.id}

        error ->
          error
          # TODO
          |> IO.inspect()
      end
    end
  end

  @doc """
  Updates a user.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a user.

  ## Examples

      iex> delete_user(user)
      {:ok, %User{}}

      iex> delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  alias Homesynck.Auth.PhoneNumber

  @doc """
  Returns the list of phone_numbers.

  ## Examples

      iex> list_phone_numbers()
      [%PhoneNumber{}, ...]

  """
  def list_phone_numbers do
    Repo.all(PhoneNumber)
  end

  def validate_register_token(_token) do
    case Repo.get_by(PhoneNumber, register_token: token) do
      %PhoneNumber{} = phone ->
        obfuscated_token =
          :crypto.strong_rand_bytes(256)
          |> :unicode.characters_to_list({:utf16, :little})

        update_phone_number(phone, %{register_token: obfuscated_token})
        :ok

      nil ->
        {:error, :not_found}
    end
  end

  def validate_phone(phone) when is_binary(phone) do
    gen = fn -> :crypto.rand_uniform(0, 9) end
    code = "#{gen.()}#{gen.()}#{gen.()}#{gen.()}#{gen.()}#{gen.()}"

    cond do
      is_phone_format_invalid?(phone) -> {:error, "invalid format"}
      is_phone_cooling_down?(phone) -> {:error, "phone not validated"}
      send_validation_sms(phone, code) != :ok -> {:error, "invalid format"}
      persist_verified_phone(phone, code) != :ok -> {:error, "code sent has error"}
      true -> {:ok, []}
    end
  end

  defp is_phone_cooling_down?(number) do
    with %PhoneNumer{expires: expires} <- Repo.get_by(PhoneNumber, number: number),
         erl_date <- Ecto.Date.to_erl(expires),
         {:ok, ndt_date} <- NaiveDateTime.from_erl(erl_date),
         :gt <- NaiveDateTime.compare(NaiveDateTime.local_now(), ndt_date) do
      false
    else
      _ -> true
    end
  end

  defp is_phone_format_invalid?(number) do
    not String.match?(number, ~r"^\+(?:[0-9] ?){6,14}[0-9]$")
  end

  defp send_validation_sms(number, code) do
    body = %{
      number: number,
      message: code,
      secret:
        "oh no"
    }

    HTTPoison.start()

    case HTTPoison.post(
           "https://infinite-badlands-29343.herokuapp.com/sms",
           Jason.encode!(body),
           [{"Content-Type", "application/json"}]
         ) do
      {:ok, %HTTPoison.Response{body: "0"}} ->
        IO.puts("Phone validation SMS sent to #{number}")
        :ok

      _ ->
        :error
    end
  end

  defp persist_verified_phone(number, code) do
    expires =
      NaiveDateTime.local_now()
      |> NaiveDateTime.add(2_592_000)
      |> NaiveDateTime.to_erl()
      |> Ecto.Date.from_erl()

    attrs = %{
      register_token: code,
      number: number,
      expires: expires
    }

    case Repo.get_by(PhoneNumber, number: number) do
      %PhoneNumber{} = existing -> update_phone_number(existing, attrs)
      nil -> create_phone_number(attrs)
    end
  end

  @doc """
  Gets a single phone_number.

  Raises `Ecto.NoResultsError` if the Phone number does not exist.

  ## Examples

      iex> get_phone_number!(123)
      %PhoneNumber{}

      iex> get_phone_number!(456)
      ** (Ecto.NoResultsError)

  """
  def get_phone_number!(id), do: Repo.get!(PhoneNumber, id)

  @doc """
  Creates a phone_number.

  ## Examples

      iex> create_phone_number(%{field: value})
      {:ok, %PhoneNumber{}}

      iex> create_phone_number(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_phone_number(attrs \\ %{}) do
    %PhoneNumber{}
    |> PhoneNumber.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a phone_number.

  ## Examples

      iex> update_phone_number(phone_number, %{field: new_value})
      {:ok, %PhoneNumber{}}

      iex> update_phone_number(phone_number, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_phone_number(%PhoneNumber{} = phone_number, attrs) do
    phone_number
    |> PhoneNumber.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a phone_number.

  ## Examples

      iex> delete_phone_number(phone_number)
      {:ok, %PhoneNumber{}}

      iex> delete_phone_number(phone_number)
      {:error, %Ecto.Changeset{}}

  """
  def delete_phone_number(%PhoneNumber{} = phone_number) do
    Repo.delete(phone_number)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking phone_number changes.

  ## Examples

      iex> change_phone_number(phone_number)
      %Ecto.Changeset{data: %PhoneNumber{}}

  """
  def change_phone_number(%PhoneNumber{} = phone_number, attrs \\ %{}) do
    PhoneNumber.changeset(phone_number, attrs)
  end
end

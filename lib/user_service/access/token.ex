defmodule UserService.Access.Token do
  use Joken.Config

  alias UserService.Access.Context

  @impl true
  def token_config do
    default_claims(iss: "user-service", skip: [:aud])
  end

  def sign_auth_token(%Context{guid: guid}) do
    signer = Joken.Signer.create("HS256", secret())
    generate_and_sign!(%{"guid" => guid, "exp" => expiration()}, signer)
  end

  defp secret() do
    Application.fetch_env!(:user_service, :api_signer_secret)
  end

  defp expiration() do
    :erlang.system_time(:seconds) + UserService.Access.token_duration_in_seconds()
  end
end

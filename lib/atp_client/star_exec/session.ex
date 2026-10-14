defmodule AtpClient.StarExec.Session do
  @moduledoc """
  An authenticated StarExec session.

  Created by `AtpClient.StarExec.login/1`. The struct holds the cookies
  returned by Tomcat's form auth (typically `JSESSIONID`) and the base URL
  those cookies are valid for, so they can be attached to every follow-up
  request without going through a cookie jar. `csrf` is the session's CSRF
  token as `{header, token}`, read from the `csrf-header` / `csrf-token` meta
  tags of a page once logged in, and sent on every request that is not a GET;
  `nil` for a StarExec that does not issue one.
  """

  @enforce_keys [:base_url]
  defstruct base_url: nil, cookies: %{}, opts: [], csrf: nil

  @type t :: %__MODULE__{
          base_url: String.t(),
          cookies: %{optional(String.t()) => String.t()},
          opts: keyword(),
          csrf: {String.t(), String.t()} | nil
        }
end

defmodule AtpClient.StarExec.Session do
  @moduledoc """
  An authenticated StarExec session.

  Created by `AtpClient.StarExec.login/1`. The struct holds the cookies
  returned by Tomcat's form auth (typically `JSESSIONID`) and the base URL
  those cookies are valid for, so they can be attached to every follow-up
  request without going through a cookie jar.
  """

  @enforce_keys [:base_url]
  defstruct base_url: nil, cookies: %{}, opts: []

  @type t :: %__MODULE__{
          base_url: String.t(),
          cookies: %{optional(String.t()) => String.t()},
          opts: keyword()
        }
end

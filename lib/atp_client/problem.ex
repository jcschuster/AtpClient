defprotocol AtpClient.Problem do
  @moduledoc """
  Deprecated: `AtpClient.Input` is the protocol backends read. Removed in 0.9.

  Every implementation delegates to `AtpClient.Input`, so code written against
  `AtpClient.Problem.to_iodata(problem)` keeps working for every input `AtpClient.Input`
  accepts. An implementation of this protocol for a type of one's own is no longer
  read by any backend; implement `AtpClient.Input` instead.
  """

  @fallback_to_any true

  @doc false
  @deprecated "Use AtpClient.Input.to_iodata/1"
  @spec to_iodata(t) :: iodata()
  def to_iodata(problem)

  @doc false
  @deprecated "Use AtpClient.Input.name/1"
  @spec name(t) :: binary() | nil
  def name(problem)
end

defimpl AtpClient.Problem, for: Any do
  def to_iodata(input), do: AtpClient.Input.to_iodata(input)
  def name(input), do: AtpClient.Input.name(input)
end

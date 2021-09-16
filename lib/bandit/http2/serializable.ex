defprotocol Bandit.HTTP2.Serializable do
  def serialize(frame)
end

defprotocol Bandit.HTTP2.Serializable do
  def serialize(frame, max_frame_size)
end

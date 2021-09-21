defprotocol Bandit.HTTP2.Serializable do
  alias Bandit.HTTP2.{Frame, Stream}

  @spec serialize(any(), non_neg_integer()) :: [
          {Frame.frame_type(), Frame.flags(), Stream.stream_id(), iodata()}
        ]
  def serialize(frame, max_frame_size)
end

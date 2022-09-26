defmodule Bandit.HTTP do
  @moduledoc false
  # Implements functions shared by different HTTP versions

  # Current DateTime formatted for HTTP headers
  def date_header do
    Calendar.strftime(DateTime.utc_now(), "%a, %-d %b %Y %X GMT")
  end
end

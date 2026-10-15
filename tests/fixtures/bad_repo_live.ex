defmodule AppWeb.PostLive.Index do
  use AppWeb, :live_view

  alias App.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :posts, Repo.all(App.Blog.Post))}
  end
end

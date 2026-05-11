defmodule InterviewWeb.PageController do
  use InterviewWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def chrome_devtools(conn, _params) do
    send_resp(conn, 204, "")
  end
end

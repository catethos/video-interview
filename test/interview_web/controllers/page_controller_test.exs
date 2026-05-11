defmodule InterviewWeb.PageControllerTest do
  use InterviewWeb.ConnCase

  test "GET / renders the landing with sign-in link", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "A question. An answer."
    assert html =~ ~s|href="/auth/sign-in"|
  end
end

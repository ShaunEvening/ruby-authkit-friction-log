require 'dotenv/load'
require 'json'
require 'sinatra'
require 'workos'

WORKOS_API_KEY = ENV['WORKOS_API_KEY']
WORKOS_CLIENT_ID = ENV['WORKOS_CLIENT_ID']
WORKOS_COOKIE_KEY = 'wos_session'
WORKOS_COOKIE_PASSWORD = ENV['WORKOS_COOKIE_PASSWORD']
WORKOS_REDIRECT_URI = ENV['WORKOS_REDIRECT_URI']

WorkOS.configure do |config|
  config.key = WORKOS_API_KEY
end

set :port, 3000
set :bind, 'localhost'

helpers do

  # Pluck the session cookie from the request
  def pluck_session_cookie(request)
    request.cookies[WORKOS_COOKIE_KEY]
  end

  # Set the session cookie in the response
  def set_session_cookie(response, sealed_session)
    response.set_cookie(
      WORKOS_COOKIE_KEY,
      value: sealed_session,
      httponly: true,
      secure: true,
      samesite: "lax"
    )
  end

  # Clear the session cookie from the response
  def clear_session_cookie(response)
    response.delete_cookie(WORKOS_COOKIE_KEY)
  end

  # Load the session from the cookie
  def load_session(client_id, cookie_password, request)
    WorkOS::UserManagement.load_sealed_session(
      client_id: client_id,
      session_data: pluck_session_cookie(request),
      cookie_password: cookie_password,
    )
  end

  # Authenticate the session
  def with_auth(request, response)
    session = load_session(WORKOS_CLIENT_ID, WORKOS_COOKIE_PASSWORD, request)

    session.authenticate => { authenticated:, reason: }

    return if authenticated == true

    redirect "/login" if !authenticated && reason == "NO_SESSION_COOKIE_PROVIDED"

    # If no session, attempt a refresh
    begin
      session.refresh => { authenticated:, sealed_session: }

      redirect "/login" if !authenticated

      set_session_cookie(response, sealed_session)

      # Redirect to the same route to ensure the updated cookie is used
      redirect request.url
    rescue => e
      warn e
      clear_session_cookie(response)
      redirect "/login"
    end
  end
end

get '/' do
  session = load_session(WORKOS_CLIENT_ID, WORKOS_COOKIE_PASSWORD, request)
  session.authenticate() => { authenticated:, user: }

  @user = authenticated ? user : nil

  erb :index
end

get '/healthcheck' do
  content_type :json

  { status: 200, message: 'Feeling good!' }.to_json
end

get "/login" do
  authorization_url = WorkOS::UserManagement.authorization_url(
    provider: "authkit",
    client_id: WORKOS_CLIENT_ID,
    redirect_uri: WORKOS_REDIRECT_URI
  )

  redirect authorization_url
end

get "/logout" do
  session = load_session(WORKOS_CLIENT_ID, WORKOS_COOKIE_PASSWORD, request)
  url = session.get_logout_url

  response.delete_cookie(WORKOS_COOKIE_KEY)

  # After log out has succeeded, the user will be redirected to your
  # app homepage which is configured in the WorkOS dashboard
  redirect url
end

get "/callback" do
  code = params["code"]

  begin
    auth_response = WorkOS::UserManagement.authenticate_with_code(
      client_id: WORKOS_CLIENT_ID,
      code: code,
      session: {
        seal_session: true,
        cookie_password: WORKOS_COOKIE_PASSWORD
      }
    )

    # store the session in a cookie
    set_session_cookie(response, auth_response[:sealed_session])

    redirect "/"
  rescue => e
    puts "ERROR: #{e}"
    redirect "/login"
  end
end

get "/dashboard" do
  with_auth(request, response)

  session = load_session(WORKOS_CLIENT_ID, WORKOS_COOKIE_PASSWORD, request)

  session.authenticate => { authenticated:, user: }

  redirect "/login" if !authenticated

  puts "User #{user[:first_name]} is logged in"

  # Render a dashboard view
end

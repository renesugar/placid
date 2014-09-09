defmodule Placid.Router do
  @moduledoc """
  `Placid.Router` defines an alternate format for `Plug.Router`
  routing. Supports all HTTP methods that `Plug.Router` supports.

  Routes are defined with the form:

      method route [guard], handler, action

  `method` is `get`, `post`, `put`, `patch`, `delete`, or `options`,
  each responsible for a single HTTP method. `method` can also be
  `any`, which will match on all HTTP methods. `handler` is any
  valid Elixir module name, and `action` is any valid function
  defined in the `handler` module.

  ## Example

      defmodule Router do
        use Placid.Router

        plug Plugs.HotCodeReload
        plug Filters.SetHeaders

        # Define your routes here
        get "/", Hello, :index
        get "/pages/:id", Hello, :show
        post "/pages", Hello, :create
        put "/pages/:id" when id == 1, Hello, :update_only_one
      end
  """

  @http_methods [ :get, :post, :put, :patch, :delete, :any ]

  ## Macros

  @doc """
  Macro used to add necessary items to a router.
  """
  defmacro __using__(_) do
    quote do
      import Placid.Response.Helpers
      import Placid.Router
      import Plug.Builder, only: [plug: 1, plug: 2]
      @before_compile Placid.Router
      @behaviour Plug
      Module.register_attribute(__MODULE__, :plugs, accumulate: true)

      # Plugs we want early in the stack
      plug Plug.Parsers, parsers: [ Placid.Request.Parsers.JSON, 
                                    :urlencoded, 
                                    :multipart ]
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # Plugs we want predefined but aren't necessary to be before
    # user-defined plugs
    defaults = [ { Plug.MethodOverride, [] },  
                 { :match, [] },
                 { :dispatch, [] } ]
    { conn, body } = Enum.reverse(defaults) ++ 
                     Module.get_attribute(env.module, :plugs)
                     |> Plug.Builder.compile

    quote do
      def init(opts) do
        opts
      end

      def call(conn, opts) do
        do_call(conn, opts)
      end

      def match(conn, _opts) do
        plug_route = __MODULE__.do_match(conn.method, conn.path_info)
        Plug.Conn.assign_private(conn, :plug_route,plug_route)
      end

      def dispatch(%Plug.Conn{ assigns: assigns } = conn, _opts) do
        Map.get(conn.private, :plug_route).(conn)
      end

      # Our default match so `Plug` doesn't fall on
      # its face when accessing an undefined route.
      def do_match(_,_) do
        fn conn -> 
          not_found conn 
        end
      end

      defp do_call(unquote(conn), _), do: unquote(body)
    end
  end

  for verb <- @http_methods do
    @doc """
    Macro for defining `#{verb |> to_string |> String.upcase}` routes.

    ## Arguments

    * `route` - `String|List`
    * `handler` - `Atom`
    * `action` - `Atom`
    """
    defmacro unquote(verb)(route, handler, action) do
      build_match unquote(verb), route, handler, action, __CALLER__
    end
  end

  @doc """
  Macro for defining `OPTIONS` routes.

  ## Arguments

  * `route` - `String|List`
  * `handler` - `Atom`
  * `action` - `Atom`
  """
  defmacro options(route, allows) do
    build_match :options, route, allows, __CALLER__
  end

  @doc """
  Macro for defining routes for custom HTTP methods.

  ## Arguments

  * `method` - `Atom`
  * `route` - `String|List`
  * `handler` - `Atom`
  * `action` - `Atom`
  """
  defmacro raw(method, route, handler, action) do
    build_match method, route, handler, action, __CALLER__
  end

  @doc """
  Creates RESTful resource endpoints for a route/handler
  combination.

  ## Example

      resource :users, Handlers.User

  expands to

      get,     "/users",           Handlers.User, :index
      post,    "/users",           Handlers.User, :create
      get,     "/users/:id",       Handlers.User, :show
      put,     "/users/:id",       Handlers.User, :update
      patch,   "/users/:id",       Handlers.User, :patch
      delete,  "/users/:id",       Handlers.User, :delete

      options, "/users",           "HEAD,GET,POST"
      options, "/users/new",       "HEAD,GET"
      options, "/users/:_id",      "HEAD,GET,PUT,PATCH,DELETE"
      options, "/users/:_id/edit", "HEAD,GET"
  """
  defmacro resource(resource, handler) do
    routes = 
      [ { :get,     "/#{resource}",           :index },
        { :post,    "/#{resource}",           :create },
        { :get,     "/#{resource}/:id",       :show },
        { :put,     "/#{resource}/:id",       :update },
        { :patch,   "/#{resource}/:id",       :patch },
        { :delete,  "/#{resource}/:id",       :delete },

        { :options, "/#{resource}",           "HEAD,GET,POST" },
        { :options, "/#{resource}/new",       "HEAD,GET" },
        { :options, "/#{resource}/:_id",      "HEAD,GET,PUT,PATCH,DELETE" },
        { :options, "/#{resource}/:_id/edit", "HEAD,GET" } ]

    
    for {method, path, action} <- routes do
      if is_atom(action) do
        build_match method, path, handler, action, __CALLER__
      else
        build_match method, path, action, __CALLER__
      end
    end
  end

  # Builds a `do_match/2` function body for a given route.
  defp build_match(:options, route, allows, caller) do
    body = quote do
        conn 
          |> Plug.Conn.resp(200, "") 
          |> Plug.Conn.put_resp_header("Allow", unquote(allows)) 
          |> Plug.Conn.send_resp
      end

    do_build_match :options, route, body, caller
  end
  defp build_match(method, route, handler, action, caller) do
    body = quote do
        opts = [ action: unquote(action), args: binding() ]
        unquote(handler).call conn, unquote(handler).init(opts)
      end

    do_build_match method, route, body, caller
  end

  defp do_build_match(:any, route, body, caller) do
    { _method, guards, _vars, match }  = prep_match :any, route, caller

    quote do
      def do_match(_, unquote(match)) when unquote(guards) do
        fn conn ->
          unquote(body)
        end
      end
    end
  end
  defp do_build_match(method, route, body, caller) do
    { method, guards, _vars, match }  = prep_match method, route, caller

    quote do
      def do_match(unquote(method), unquote(match)) when unquote(guards) do
        fn conn ->
          unquote(body)
        end
      end
    end
  end

  defp prep_match(method, route, caller) do
    { method, guard } = convert_methods(List.wrap(method))
    { path, guards }  = extract_path_and_guards(route, guard)
    { vars, match }   = apply Plug.Router.Utils, 
                              :build_match, 
                              [ Macro.expand(path, caller) ]
    { method, guards, vars, match }
  end

  ## Grabbed from `Plug.Router`

  # Convert the verbs given with :via into a variable
  # and guard set that can be added to the dispatch clause.
  defp convert_methods([]) do
    { quote(do: _), true }
  end

  defp convert_methods([method]) do
    { Plug.Router.Utils.normalize_method(method), true }
  end

  # Extract the path and guards from the path.
  defp extract_path_and_guards({ :when, _, [ path, guards ] }, true) do
    { path, guards }
  end

  defp extract_path_and_guards({ :when, _, [ path, guards ] }, extra_guard) do
    { path, { :and, [], [ guards, extra_guard ] } }
  end

  defp extract_path_and_guards(path, extra_guard) do
    { path, extra_guard }
  end
end
require "kemal"
require "ecr"
require "json"
require "uuid"
require "stripe"
require "./auth"
require "./alias"
require "./team"

# Database setup
DB::DATABASE = SQLite3::DB.open(ENV["DATABASE_URL"]? || "email_me.db")
DB.setup

# Stripe setup
Stripe.api_key = ENV["STRIPE_SECRET_KEY"] || raise "STRIPE_SECRET_KEY not set"
STRIPE_PUBLIC_KEY = ENV["STRIPE_PUBLIC_KEY"] || raise "STRIPE_PUBLIC_KEY not set"
PRO_PRICE_ID = ENV["STRIPE_PRO_PRICE_ID"] || "price_pro"
UNLIMITED_PRICE_ID = ENV["STRIPE_UNLIMITED_PRICE_ID"] || "price_unlimited"

# Session management
SESSION_STORE = {} of String => Int32

# Helper to get current user
def current_user(context)
  token = context.request.cookies["auth_token"]?.try(&.value)
  return nil if token.nil?
  Auth.authenticate(token)
end

def require_login(context)
  user = current_user(context)
  if user.nil?
    context.redirect "/signup"
    return nil
  end
  user
end

# Routes

# Landing page
get "/" do |env|
  domain = Alias::DEFAULT_DOMAIN
  response = env.response
  response.content_type = "text/html"
  ECR.render("views/index.ecr")
end

# Pricing page
get "/pricing" do |env|
  domain = Alias::DEFAULT_DOMAIN
  response = env.response
  response.content_type = "text/html"
  ECR.render("views/pricing.ecr")
end

# Signup/Login page
get "/signup" do |env|
  response = env.response
  response.content_type = "text/html"
  login_error = ""
  login_email_or_username = ""
  signup_error = ""
  signup_success = ""
  signup_email = ""
  signup_username = ""
  ECR.render("views/signup.ecr")
end

# Login handler
post "/login" do |env|
  params = env.params.body
  email_or_username = params["email_or_username"]?.to_s
  password = params["password"]?.to_s
  
  success, result = Auth.login(email_or_username, password)
  
  if success
    token = result.as(String)
    env.response.cookies["auth_token"] = HTTP::Cookie.new("auth_token", token, path: "/", httponly: true, max_age: 7.days)
    env.redirect "/dashboard"
  else
    error = result.as(String)
    response = env.response
    response.content_type = "text/html"
    login_error = error
    login_email_or_username = email_or_username
    signup_error = ""
    signup_success = ""
    signup_email = ""
    signup_username = ""
    ECR.render("views/signup.ecr")
  end
end

# Signup handler
post "/signup" do |env|
  params = env.params.body
  email = params["email"]?.to_s
  username = params["username"]?.to_s
  password = params["password"]?.to_s
  password_confirm = params["password_confirm"]?.to_s
  
  if password != password_confirm
    response = env.response
    response.content_type = "text/html"
    login_error = ""
    login_email_or_username = ""
    signup_error = "Passwords do not match"
    signup_success = ""
    signup_email = email
    signup_username = username
    return ECR.render("views/signup.ecr")
  end
  
  success, result = Auth.register(email, username, password)
  
  if success
    response = env.response
    response.content_type = "text/html"
    login_error = ""
    login_email_or_username = ""
    signup_error = ""
    signup_success = "Account created! Please log in."
    signup_email = ""
    signup_username = ""
    ECR.render("views/signup.ecr")
  else
    error = result.as(String)
    response = env.response
    response.content_type = "text/html"
    login_error = ""
    login_email_or_username = ""
    signup_error = error
    signup_success = ""
    signup_email = email
    signup_username = username
    ECR.render("views/signup.ecr")
  end
end

# Logout
get "/logout" do |env|
  env.response.cookies.delete("auth_token")
  env.redirect "/"
end

# Dashboard
get "/dashboard" do |env|
  user = require_login(env)
  return unless user
  
  # Get user data
  user_obj = User.find_by_id(user.id).not_nil!
  aliases = Alias.find_by_user(user.id)
  plan = user_obj.plan || "Free"
  forward_to = user_obj.forward_email || "Not set"
  
  response = env.response
  response.content_type = "text/html"
  username = user.username
  email = user.email
  alias_count = aliases.size
  recent_aliases = aliases.first(5)
  ECR.render("views/dashboard.ecr")
end

# Alias management page
get "/alias" do |env|
  user = require_login(env)
  return unless user
  
  aliases = Alias.find_by_user(user.id)
  plan = User.find_by_id(user.id).not_nil!.plan || "Free"
  domain = Alias::DEFAULT_DOMAIN
  
  response = env.response
  response.content_type = "text/html"
  error_message = ""
  success_message = ""
  ECR.render("views/alias.ecr")
end

# Create alias
post "/alias/create" do |env|
  user = require_login(env)
  return unless user
  
  params = env.params.body
  local_part = params["local_part"]?.to_s
  forward_to = params["forward_to"]?.to_s
  domain = Alias::DEFAULT_DOMAIN
  
  user_obj = User.find_by_id(user.id).not_nil!
  is_paid = user_obj.plan != "Free"
  
  success, result = Alias.create(user.id, local_part, domain, forward_to, is_paid)
  
  if success
    # Call Cloudflare to create forwarding rule
    new_alias = Alias.find_by_id(result.as(Int32)).not_nil!
    cf_success, cf_result = Cloudflare.sync_alias(new_alias, "create")
    unless cf_success
      # Rollback alias creation if Cloudflare fails
      Alias.delete(result.as(Int32), user.id, true)
      error_message = "Failed to create forwarding rule: #{cf_result}"
      aliases = Alias.find_by_user(user.id)
      plan = user_obj.plan || "Free"
      domain = Alias::DEFAULT_DOMAIN
      success_message = ""
      return ECR.render("views/alias.ecr")
    end
    env.redirect "/alias"
  else
    error_message = result.as(String)
    aliases = Alias.find_by_user(user.id)
    plan = user_obj.plan || "Free"
    domain = Alias::DEFAULT_DOMAIN
    success_message = ""
    response = env.response
    response.content_type = "text/html"
    ECR.render("views/alias.ecr")
  end
end

# Delete alias
post "/alias/delete" do |env|
  user = require_login(env)
  return unless user
  
  params = env.params.body
  alias_id = params["alias_id"]?.to_s.to_i
  
  alias_obj = Alias.find_by_id(alias_id)
  if alias_obj && alias_obj.user_id == user.id
    # Delete from Cloudflare first
    Cloudflare.sync_alias(alias_obj, "delete")
    # Delete from database
    Alias.delete(alias_id, user.id, false)
  end
  
  env.redirect "/alias"
end

# Team management page
get "/team" do |env|
  user = require_login(env)
  return unless user
  
  user_obj = User.find_by_id(user.id).not_nil!
  plan = user_obj.plan || "Free"
  domains = Team.get_user_domains(user.id)
  
  # Get team members for each domain
  team_members = {} of Int32 => Array(TeamMember)
  domains.each do |domain|
    team_members[domain.id] = Team.get_team_members(domain.id, user.id)
  end
  
  response = env.response
  response.content_type = "text/html"
  success_message = ""
  error_message = ""
  ECR.render("views/team.ecr")
end

# Add custom domain
post "/team/domain/add" do |env|
  user = require_login(env)
  return unless user
  
  params = env.params.body
  domain = params["domain"]?.to_s
  
  success, result = Team.add_domain(domain, user.id)
  
  if success
    env.redirect "/team"
  else
    error_message = result.as(String)
    user_obj = User.find_by_id(user.id).not_nil!
    plan = user_obj.plan || "Free"
    domains = Team.get_user_domains(user.id)
    team_members = {} of Int32 => Array(TeamMember)
    domains.each do |d|
      team_members[d.id] = Team.get_team_members(d.id, user.id)
    end
    success_message = ""
    response = env.response
    response.content_type = "text/html"
    ECR.render("views/team.ecr")
  end
end

# Invite team member
post "/team/invite" do |env|
  user = require_login(env)
  return unless user
  
  params = env.params.body
  domain_id = params["domain_id"]?.to_s.to_i
  invitee_email = params["invitee_email"]?.to_s
  role = params["role"]?.to_s || "member"
  
  success, message = Team.invite_member(domain_id, user.id, invitee_email, role)
  
  if success
    env.redirect "/team"
  else
    error_message = message
    user_obj = User.find_by_id(user.id).not_nil!
    plan = user_obj.plan || "Free"
    domains = Team.get_user_domains(user.id)
    team_members = {} of Int32 => Array(TeamMember)
    domains.each do |d|
      team_members[d.id] = Team.get_team_members(d.id, user.id)
    end
    success_message = ""
    response = env.response
    response.content_type = "text/html"
    ECR.render("views/team.ecr")
  end
end

# Remove team member
post "/team/remove" do |env|
  user = require_login(env)
  return unless user
  
  params = env.params.body
  domain_id = params["domain_id"]?.to_s.to_i
  member_id = params["member_id"]?.to_s.to_i
  
  Team.remove_member(domain_id, user.id, member_id)
  env.redirect "/team"
end

# Pro checkout
get "/pro" do |env|
  user = require_login(env)
  return unless user
  
  response = env.response
  response.content_type = "text/html"
  stripe_public_key = STRIPE_PUBLIC_KEY
  price_id = PRO_PRICE_ID
  ECR.render("views/checkout.ecr")
end

# Unlimited checkout
get "/unlimited" do |env|
  user = require_login(env)
  return unless user
  
  response = env.response
  response.content_type = "text/html"
  stripe_public_key = STRIPE_PUBLIC_KEY
  price_id = UNLIMITED_PRICE_ID
  ECR.render("views/checkout.ecr")
end

# Create Stripe checkout session
post "/create-checkout-session" do |env|
  user = require_login(env)
  return unless user
  
  params = env.params.body
  price_id = params["price_id"]?.to_s
  
  session = Stripe::Checkout::Session.create({
    success_url: "#{ENV["APP_URL"]}/payment-success?session_id={CHECKOUT_SESSION_ID}",
    cancel_url: "#{ENV["APP_URL"]}/pricing",
    mode: "subscription",
    customer_email: user.email,
    line_items: [{
      quantity: 1,
      price: price_id
    }]
  })
  
  env.response.headers["Content-Type"] = "application/json"
  {"id" => session.id}.to_json
end

# Payment success
get "/payment-success" do |env|
  user = require_login(env)
  return unless user
  
  session_id = env.params.query["session_id"]?.to_s
  
  begin
    session = Stripe::Checkout::Session.retrieve(session_id)
    
    if session.payment_status == "paid"
      # Determine plan from price ID
      price_id = session.line_items.data.first.price.id
      plan = case price_id
             when PRO_PRICE_ID then "Pro"
             when UNLIMITED_PRICE_ID then "Unlimited"
             else "Free"
             end
      
      # Update user's plan in database
      DB::DATABASE.exec(
        "UPDATE users SET plan = $1, stripe_customer_id = $2 WHERE id = $3",
        plan, session.customer, user.id
      )
      
      response = env.response
      response.content_type = "text/html"
      success_message = "Payment successful! Your plan has been upgraded to #{plan}."
      ECR.render("views/payment-success.ecr")
    else
      env.redirect "/pricing"
    end
  rescue ex
    env.redirect "/pricing"
  end
end

# Webhook for Stripe events
post "/stripe-webhook" do |env|
  payload = env.request.body.not_nil!.gets_to_end
  sig_header = env.request.headers["Stripe-Signature"]?.to_s
  webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"] || ""
  
  begin
    event = Stripe::Webhook.construct_event(payload, sig_header, webhook_secret)
    
    case event.type
    when "customer.subscription.deleted"
      # Handle subscription cancellation
      customer_id = event.data.object.customer
      DB::DATABASE.exec(
        "UPDATE users SET plan = 'Free' WHERE stripe_customer_id = $1",
        customer_id
      )
    when "invoice.payment_failed"
      # Handle failed payment
      customer_id = event.data.object.customer
      DB::DATABASE.exec(
        "UPDATE users SET plan = 'Free' WHERE stripe_customer_id = $1",
        customer_id
      )
    end
    
    env.response.status_code = 200
    env.response.print("Webhook received")
  rescue ex
    env.response.status_code = 400
    env.response.print("Webhook error")
  end
end

# Cancel subscription
post "/cancel-subscription" do |env|
  user = require_login(env)
  return unless user
  
  user_obj = User.find_by_id(user.id).not_nil!
  customer_id = user_obj.stripe_customer_id
  
  if customer_id && !customer_id.empty?
    # Get active subscriptions
    subscriptions = Stripe::Subscription.list({customer: customer_id, status: "active"})
    subscriptions.data.each do |sub|
      Stripe::Subscription.cancel(sub.id)
    end
    
    DB::DATABASE.exec(
      "UPDATE users SET plan = 'Free' WHERE id = $1",
      user.id
    )
  end
  
  env.redirect "/dashboard"
end

# Start server
port = (ENV["PORT"]? || "3000").to_i
puts "Server running on http://localhost:#{port}"
Kemal.run(port)

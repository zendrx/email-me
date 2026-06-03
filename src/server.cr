require "kemal"
require "ecr"
require "json"
require "uuid"
require "db"
require "sqlite3"
require "crypto/bcrypt/password"
require "jwt"
require "./email-me/*"
# Helper to get current user
def current_user(env)
  token = env.request.cookies["auth_token"]?.try(&.value)
  return nil if token.nil?
  Auth.authenticate(token)
end

def require_login(env)
  user = current_user(env)
  if user.nil?
    env.redirect "/signup"
    return nil
  end
  user
end

# Helper to get user object with plan
def get_user_with_plan(user_id : Int32)
  DB.open(DAB::DB_PATH) do |db|
    result = db.query_one?("SELECT id, email, username, plan, forward_email FROM users WHERE id = ?", user_id, as: {Int32, String, String, String?, String?})
    return nil if result.nil?
    id, email, username, plan, forward_email = result
    {id: id, email: email, username: username, plan: plan || "Free", forward_email: forward_email}
  end
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
    env.response.cookies["auth_token"] = HTTP::Cookie.new("auth_token", token, path: "/", http_only: true, max_age: 7.days)
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
    next ECR.render("views/signup.ecr")
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
  next unless user
  
  user_data = get_user_with_plan(user.id).not_nil!
  aliases = Alias.find_by_user(user.id)
  
  response = env.response
  response.content_type = "text/html"
  username = user_data[:username]
  email = user_data[:email]
  plan = user_data[:plan]
  forward_to = user_data[:forward_email] || "Not set"
  alias_count = aliases.size
  recent_aliases = aliases.first(5)
  ECR.render("views/dashboard.ecr")
end

# Alias management page
get "/alias" do |env|
  user = require_login(env)
  next unless user
  
  user_data = get_user_with_plan(user.id).not_nil!
  aliases = Alias.find_by_user(user.id)
  plan = user_data[:plan]
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
  next unless user
  
  params = env.params.body
  local_part = params["local_part"]?.to_s
  forward_to = params["forward_to"]?.to_s
  domain = Alias::DEFAULT_DOMAIN
  
  user_data = get_user_with_plan(user.id).not_nil!
  is_paid = user_data[:plan] != "Free"
  
  success, result = Alias.create(user.id, local_part, domain, forward_to, is_paid)
  
  if success
    new_alias = Alias.find_by_id(result.as(Int32))
    if new_alias
      cf_success, cf_result = Cloudflare.sync_alias(new_alias, "create")
      unless cf_success
        Alias.delete(result.as(Int32), user.id, true)
        error_message = "Failed to create forwarding rule: #{cf_result}"
        aliases = Alias.find_by_user(user.id)
        plan = user_data[:plan]
        domain = Alias::DEFAULT_DOMAIN
        success_message = ""
        next ECR.render("views/alias.ecr")
      end
    end
    env.redirect "/alias"
  else
    error_message = result.as(String)
    aliases = Alias.find_by_user(user.id)
    plan = user_data[:plan]
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
  next unless user
  
  params = env.params.body
  alias_id = params["alias_id"]?.to_s.to_i
  
  alias_obj = Alias.find_by_id(alias_id)
  if alias_obj && alias_obj.user_id == user.id
    Cloudflare.sync_alias(alias_obj, "delete")
    Alias.delete(alias_id, user.id, false)
  end
  
  env.redirect "/alias"
end

# Team management page
get "/team" do |env|
  user = require_login(env)
  next unless user
  
  user_data = get_user_with_plan(user.id).not_nil!
  plan = user_data[:plan]
  domains = Team.get_user_domains(user.id)
  
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
  next unless user
  
  params = env.params.body
  domain = params["domain"]?.to_s
  
  success, result = Team.add_domain(domain, user.id)
  
  if success
    env.redirect "/team"
  else
    error_message = result.as(String)
    user_data = get_user_with_plan(user.id).not_nil!
    plan = user_data[:plan]
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
  next unless user
  
  params = env.params.body
  domain_id = params["domain_id"]?.to_s.to_i
  invitee_email = params["invitee_email"]?.to_s
  role = params["role"]?.to_s || "member"
  
  success, message = Team.invite_member(domain_id, user.id, invitee_email, role)
  
  if success
    env.redirect "/team"
  else
    error_message = message
    user_data = get_user_with_plan(user.id).not_nil!
    plan = user_data[:plan]
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
  next unless user
  
  params = env.params.body
  domain_id = params["domain_id"]?.to_s.to_i
  member_id = params["member_id"]?.to_s.to_i
  
  Team.remove_member(domain_id, user.id, member_id)
  env.redirect "/team"
end

# Pro checkout page
get "/pro" do |env|
  user = require_login(env)
  next unless user
  
  response = env.response
  response.content_type = "text/html"
  public_key = Paystack::PUBLIC_KEY
  amount = Paystack::PRO_AMOUNT
  plan_name = "Pro"
  ECR.render("views/checkout-paystack.ecr")
end

# Unlimited checkout page
get "/unlimited" do |env|
  user = require_login(env)
  next unless user
  
  response = env.response
  response.content_type = "text/html"
  public_key = Paystack::PUBLIC_KEY
  amount = Paystack::UNLIMITED_AMOUNT
  plan_name = "Unlimited"
  ECR.render("views/checkout-paystack.ecr")
end

# Initialize Paystack payment
post "/paystack/initialize" do |env|
  user = require_login(env)
  next unless user
  
  params = env.params.body
  plan = params["plan"]?.to_s
  email = user.email
  
  amount = case plan
           when "Pro" then Paystack::PRO_AMOUNT
           when "Unlimited" then Paystack::UNLIMITED_AMOUNT
           else 0
           end
  
  callback_url = "#{ENV["APP_URL"]}/paystack/callback"
  
  result = Paystack.initialize_transaction(email, amount, plan, user.id, callback_url)
  
  env.response.headers["Content-Type"] = "application/json"
  if result.status && result.data
    {"status" => true, "authorization_url" => result.data.not_nil!.authorization_url, "reference" => result.data.not_nil!.reference}.to_json
  else
    {"status" => false, "message" => result.message}.to_json
  end
end

# Paystack callback
get "/paystack/callback" do |env|
  user = require_login(env)
  next unless user
  
  reference = env.params.query["reference"]?.to_s
  
  if reference.empty?
    env.redirect "/pricing?error=missing_reference"
    next
  end
  
  result = Paystack.verify_transaction(reference)
  
  if result.status && result.data && result.data.not_nil!.status == "success"
    metadata = result.data.not_nil!.metadata
    plan = metadata ? metadata.plan : "Pro"
    
    DB.open(DAB::DB_PATH) do |db|
      db.exec(
        "UPDATE users SET plan = ? WHERE id = ?",
        plan, user.id
      )
    end
    
    response = env.response
    response.content_type = "text/html"
    success_message = "Payment successful! Your plan has been upgraded to #{plan}."
    ECR.render("views/payment-success.ecr")
  else
    env.redirect "/pricing?error=payment_failed"
  end
end

# Paystack webhook
post "/paystack/webhook" do |env|
  payload = env.request.body.not_nil!.gets_to_end
  signature = env.request.headers["X-Paystack-Signature"]?.to_s
  
  event = Paystack.parse_webhook(payload, signature)
  
  if event
    case event.event
    when "charge.success"
      reference = event.data.reference
      amount = event.data.amount
      metadata = event.data.metadata
      
      if metadata
        user_id = metadata.user_id
        plan = metadata.plan
        
        DB.open(DAB::DB_PATH) do |db|
          db.exec(
            "UPDATE users SET plan = ? WHERE id = ?",
            plan, user_id
          )
        end
      end
    when "subscription.disable"
      # Handle subscription cancellation
      reference = event.data.reference
      DB.open(DAB::DB_PATH) do |db|
        db.exec(
          "UPDATE users SET plan = 'Free' WHERE stripe_customer_id IS NULL AND id IN (SELECT user_id FROM users WHERE email = ?)",
          event.data.customer.email
        )
      end
    end
    
    env.response.status_code = 200
    env.response.print("OK")
  else
    env.response.status_code = 401
    env.response.print("Invalid signature")
  end
end

# Cancel subscription (redirect to team page for now)
post "/cancel-subscription" do |env|
  user = require_login(env)
  next unless user
  
  DB.open(DAB::DB_PATH) do |db|
    db.exec(
      "UPDATE users SET plan = 'Free' WHERE id = ?",
      user.id
    )
  end
  
  env.redirect "/dashboard"
end

# Start server
port = (ENV["PORT"]? || "3000").to_i
puts "Email Me server running on http://localhost:#{port}"
Kemal.run(port)

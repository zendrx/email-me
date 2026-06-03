require "jwt"
require "crypto/bcrypt/password"
require "json"
require "./db"

class Auth
  JWT_SECRET = ENV["JWT_SECRET"]? || raise "JWT_SECRET environment variable not set"
  JWT_TTL = 7.days

  struct UserPayload
    include JSON::Serializable
    
    property id : Int32
    property email : String
    property username : String
    property exp : Int64
    
    def initialize(@id : Int32, @email : String, @username : String)
      @exp = (Time.utc + Auth::JWT_TTL).to_unix
    end
  end

  def self.register(email : String, username : String, password : String) : Tuple(Bool, String | Int64)
    # Validate inputs
    return {false, "Email is required"} if email.empty?
    return {false, "Username is required"} if username.empty?
    return {false, "Password is required"} if password.empty?
    return {false, "Password must be at least 8 characters"} if password.size < 8
    
    # Check if user exists
    if DAB.email_exists?(email)
      return {false, "Email already registered"}
    end
    
    if DAB.username_exists?(username)
      return {false, "Username already taken"}
    end
    
    # Hash password and create user
    password_hash = Crypto::Bcrypt::Password.create(password, cost: 10).to_s
    user_id = DAB.create_user(email, username, password_hash)
    
    return {true, user_id}
  end

  def self.login(email_or_username : String, password : String) : Tuple(Bool, String | String)
    # Find user by email or username
    user = DAB.find_user(email_or_username)
    
    if user.nil?
      return {false, "Invalid email/username or password"}
    end
    
    # Verify password
    stored_hash = Crypto::Bcrypt::Password.create(user[:password_hash], cost: 10)
    if stored_hash.verify(password)
      # Generate JWT
      payload = UserPayload.new(
        id: user[:id],
        email: user[:email],
        username: user[:username]
      )
      token = JWT.encode(payload.to_json, JWT_SECRET, JWT::Algorithm::HS256)
      return {true, token}
    else
      return {false, "Invalid email/username or password"}
    end
  end

  def self.authenticate(token : String?) : UserPayload?
    return nil if token.nil?
    
    begin
      decoded = JWT.decode(token, JWT_SECRET, JWT::Algorithm::HS256)
      payload_data = JSON.parse(decoded[0].to_s)
      
      # Check expiration
      exp = payload_data["exp"]?.try(&.as_i64)
      if exp && exp <= Time.utc.to_unix
        return nil
      end
      
      UserPayload.from_json(payload_data.to_json)
    rescue
      nil
    end
  end

  def self.validate_token(token : String) : Bool
    !authenticate(token).nil?
  end

  def self.get_user_from_token(token : String) : UserPayload?
    authenticate(token)
  end
end

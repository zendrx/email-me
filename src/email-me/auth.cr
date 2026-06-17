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

  def self.register(email : String, username : String, password : String) : Tuple(Bool, String | Int32)
    return {false, "Email is required"} if email.empty?
    return {false, "Username is required"} if username.empty?
    return {false, "Password is required"} if password.empty?
    return {false, "Password must be at least 8 characters"} if password.size < 8

    if email_exists?(email)
      return {false, "Email already registered"}
    end

    if username_exists?(username)
      return {false, "Username already taken"}
    end

    password_hash = Crypto::Bcrypt::Password.create(password, cost: 10).to_s
    user_id = create_user(email, username, password_hash)

    {true, user_id}
  end

  def self.login(email_or_username : String, password : String) : Tuple(Bool, String | String)
    user = find_user(email_or_username)

    if user.nil?
      return {false, "Invalid email/username or password"}
    end

    # CORRECT: Use Password.new to wrap stored hash, then verify
    stored_hash = Crypto::Bcrypt::Password.new(user[:password_hash])
    if stored_hash.verify(password)
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

  private def self.email_exists?(email : String) : Bool
    result = EmailMe::DB.connection.query_one?(
      "SELECT 1 FROM users WHERE email = $1 LIMIT 1",
      email, as: Int32
    )
    !result.nil?
  end

  private def self.username_exists?(username : String) : Bool
    result = EmailMe::DB.connection.query_one?(
      "SELECT 1 FROM users WHERE username = $1 LIMIT 1",
      username, as: Int32
    )
    !result.nil?
  end

  private def self.create_user(email : String, username : String, password_hash : String) : Int32
    EmailMe::DB.connection.exec(
      "INSERT INTO users (email, username, password_hash, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5)",
      email, username, password_hash, Time.utc, Time.utc
    )

    EmailMe::DB.connection.query_one(
      "SELECT currval('users_id_seq')",
      as: Int32
    )
  end

  private def self.find_user(email_or_username : String) : NamedTuple(id: Int32, email: String, username: String, password_hash: String)?
    result = EmailMe::DB.connection.query_one?(
      "SELECT id, email, username, password_hash
       FROM users
       WHERE email = $1
       LIMIT 1",
      email_or_username, as: {Int32, String, String, String}
    )

    if result.nil?
      result = EmailMe::DB.connection.query_one?(
        "SELECT id, email, username, password_hash
         FROM users
         WHERE username = $1
         LIMIT 1",
        email_or_username, as: {Int32, String, String, String}
      )
    end

    return nil if result.nil?

    id, email, username, password_hash = result
    {id: id, email: email, username: username, password_hash: password_hash}
  end
end

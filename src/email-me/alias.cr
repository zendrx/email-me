require "json"
require "./db"

class Alias
  property id : Int32
  property user_id : Int32
  property local_part : String
  property domain : String
  property forward_to : String
  property active : Bool

  DEFAULT_DOMAIN = ENV["APP_DOMAIN"]? || "yourdomain.com"

  def initialize(@id : Int32, @user_id : Int32, @local_part : String, 
                 @domain : String, @forward_to : String, @active : Bool)
  end

  def full_email : String
    "#{@local_part}@#{@domain}"
  end

  def self.available?(local_part : String, domain : String) : Bool
    result = DB::DATABASE.query_one?(
      "SELECT 1 FROM aliases WHERE local_part = $1 AND domain = $2 AND active = true LIMIT 1",
      local_part, domain, as: Int32
    )
    result.nil?
  end

  def self.create(user_id : Int32, local_part : String, domain : String, forward_to : String, is_paid_user : Bool = false) : Tuple(Bool, String | Int32)
    # Validate local_part
    unless local_part.match?(/^[a-zA-Z0-9._-]+$/)
      return {false, "Invalid alias name. Use letters, numbers, dots, underscores, or hyphens"}
    end
    
    # Validate forward_to email
    unless forward_to.match?(/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
      return {false, "Invalid forwarding email address"}
    end
    
    # Check if user can use this domain
    if domain != DEFAULT_DOMAIN && !is_paid_user
      return {false, "Custom domains require a paid subscription"}
    end
    
    # Check if available
    unless available?(local_part, domain)
      return {false, "Alias already taken"}
    end
    
    # Create alias
    DB::DATABASE.exec(
      "INSERT INTO aliases (user_id, local_part, domain, forward_to, active, created_at) 
       VALUES ($1, $2, $3, $4, $5, $6)",
      user_id, local_part, domain, forward_to, true, Time.utc
    )
    
    alias_id = DB::DATABASE.scalar("SELECT last_insert_rowid()", as: Int32)
    {true, alias_id}
  rescue ex
    {false, "Database error: #{ex.message}"}
  end

  def self.delete(alias_id : Int32, user_id : Int32) : Bool
    result = DB::DATABASE.exec(
      "UPDATE aliases SET active = false WHERE id = $1 AND user_id = $2",
      alias_id, user_id
    )
    result.rows_affected > 0
  end

  def self.find_by_user(user_id : Int32, active_only : Bool = true) : Array(Alias)
    query = "SELECT id, user_id, local_part, domain, forward_to, active 
             FROM aliases WHERE user_id = $1"
    query += " AND active = true" if active_only
    
    results = DB::DATABASE.query_all(query, user_id, as: {Int32, Int32, String, String, String, Bool})
    
    results.map do |row|
      id, uid, local, domain, forward, active = row
      Alias.new(id, uid, local, domain, forward, active)
    end
  end

  def self.find_by_email(full_email : String) : Alias?
    parts = full_email.split('@')
    return nil if parts.size != 2
    local, domain = parts[0], parts[1]
    
    result = DB::DATABASE.query_one?(
      "SELECT id, user_id, local_part, domain, forward_to, active 
       FROM aliases WHERE local_part = $1 AND domain = $2 AND active = true",
      local, domain, as: {Int32, Int32, String, String, String, Bool}
    )
    
    return nil if result.nil?
    id, uid, local, domain, forward, active = result
    Alias.new(id, uid, local, domain, forward, active)
  end

  def self.get_domains_for_user(user_id : Int32) : Array(String)
    results = DB::DATABASE.query_all(
      "SELECT DISTINCT domain FROM aliases WHERE user_id = $1 AND active = true",
      user_id, as: String
    )
    
    # Always include default domain if user has any aliases on it
    domains = results.to_a
    if DB::DATABASE.query_one?("SELECT 1 FROM aliases WHERE user_id = $1 AND domain = $2 LIMIT 1", user_id, DEFAULT_DOMAIN, as: Int32)
      domains << DEFAULT_DOMAIN unless domains.includes?(DEFAULT_DOMAIN)
    end
    
    domains
  end

  def to_json : String
    {
      id: @id,
      local_part: @local_part,
      domain: @domain,
      forward_to: @forward_to,
      full_email: full_email,
      active: @active
    }.to_json
  end
end

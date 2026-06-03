require "json"
require "./db"
require "./team"

class Alias
  property id : Int32
  property user_id : Int32
  property local_part : String
  property domain : String
  property forward_to : String
  property active : Bool
  property created_at : Time

  DEFAULT_DOMAIN = ENV["APP_DOMAIN"]? || "yourdomain.com"

  def initialize(@id : Int32, @user_id : Int32, @local_part : String, 
                 @domain : String, @forward_to : String, @active : Bool, @created_at : Time)
  end

  def full_email : String
    "#{@local_part}@#{@domain}"
  end

  def self.available?(local_part : String, domain : String) : Bool
    DB.open(DAB::DB_PATH) do |db|
      result = db.query_one?(
        "SELECT 1 FROM aliases WHERE local_part = ? AND domain = ? AND active = true LIMIT 1",
        local_part, domain, as: Int32
      )
      result.nil?
    end
  end

  def self.create(user_id : Int32, local_part : String, domain : String, forward_to : String, is_paid_user : Bool = false) : Tuple(Bool, String | Int32)
    # Validate local_part
    unless local_part.match(/^[a-zA-Z0-9._-]+$/)
      return {false, "Invalid alias name. Use letters, numbers, dots, underscores, or hyphens"}
    end
    
    # Validate forward_to email
    unless forward_to.match(/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
      return {false, "Invalid forwarding email address"}
    end
    
    # Check if user can use this domain
    if domain != DEFAULT_DOMAIN
      unless is_paid_user
        return {false, "Custom domains require a paid subscription"}
      end
      
      # Check team permission for custom domain
      unless Team.can_create_alias?(user_id, domain)
        return {false, "You don't have permission to create aliases on this domain"}
      end
    end
    
    # Check if available
    unless available?(local_part, domain)
      return {false, "Alias already taken"}
    end
    
    # Create alias
    DB.open(DAB::DB_PATH) do |db|
      db.exec(
        "INSERT INTO aliases (user_id, local_part, domain, forward_to, active, created_at) 
         VALUES (?, ?, ?, ?, ?, ?)",
        user_id, local_part, domain, forward_to, true, Time.utc
      )
      
      alias_id = db.query_one?("SELECT last_insert_rowid()", as: Int32) || 0
      return {true, alias_id}
    end
  rescue ex
    {false, "Database error: #{ex.message}"}
  end

  def self.delete(alias_id : Int32, user_id : Int32, is_admin : Bool = false) : Bool
    # Get alias info first
    alias_info = find_by_id(alias_id)
    return false if alias_info.nil?
    
    # Check if user is domain owner or admin for this domain
    if alias_info.domain != DEFAULT_DOMAIN
      DB.open(DAB::DB_PATH) do |db|
        domain_owner = db.query_one?(
          "SELECT owner_id FROM domains WHERE domain = ?",
          alias_info.domain, as: Int32
        )
        
        # Domain owner or admin can delete any alias
        if domain_owner == user_id || Team.can_manage_team?(get_domain_id(alias_info.domain), user_id)
          is_admin = true
        end
      end
    end
    
    # Regular user can only delete their own aliases unless admin
    DB.open(DAB::DB_PATH) do |db|
      if is_admin
        result = db.exec(
          "UPDATE aliases SET active = false WHERE id = ?",
          alias_id
        )
      else
        result = db.exec(
          "UPDATE aliases SET active = false WHERE id = ? AND user_id = ?",
          alias_id, user_id
        )
      end
      
      result.rows_affected > 0
    end
  end

  def self.find_by_user(user_id : Int32, active_only : Bool = true) : Array(Alias)
    query = "SELECT id, user_id, local_part, domain, forward_to, active, created_at 
             FROM aliases WHERE user_id = ?"
    query += " AND active = true" if active_only
    
    DB.open(DAB::DB_PATH) do |db|
      results = db.query_all(query, user_id, as: {Int32, Int32, String, String, String, Bool, Time})
      
      results.map do |row|
        id, uid, local, domain, forward, active, created = row
        Alias.new(id, uid, local, domain, forward, active, created)
      end
    end
  end

  def self.find_by_id(alias_id : Int32) : Alias?
    DB.open(DAB::DB_PATH) do |db|
      result = db.query_one?(
        "SELECT id, user_id, local_part, domain, forward_to, active, created_at 
         FROM aliases WHERE id = ?",
        alias_id, as: {Int32, Int32, String, String, String, Bool, Time}
      )
      
      return nil if result.nil?
      id, uid, local, domain, forward, active, created = result
      Alias.new(id, uid, local, domain, forward, active, created)
    end
  end

  def self.find_by_email(full_email : String) : Alias?
    parts = full_email.split('@')
    return nil if parts.size != 2
    local, domain = parts[0], parts[1]
    
    DB.open(DAB::DB_PATH) do |db|
      result = db.query_one?(
        "SELECT id, user_id, local_part, domain, forward_to, active, created_at 
         FROM aliases WHERE local_part = ? AND domain = ? AND active = true",
        local, domain, as: {Int32, Int32, String, String, String, Bool, Time}
      )
      
      return nil if result.nil?
      id, uid, local, domain, forward, active, created = result
      Alias.new(id, uid, local, domain, forward, active, created)
    end
  end

  def self.get_domains_for_user(user_id : Int32) : Array(String)
    DB.open(DAB::DB_PATH) do |db|
      # Own aliases domains
      results = db.query_all(
        "SELECT DISTINCT domain FROM aliases WHERE user_id = ? AND active = true",
        user_id, as: String
      )
      
      # Team domains
      team_domains = db.query_all(
        "SELECT d.domain 
         FROM domains d
         JOIN team_members tm ON tm.domain_id = d.id
         WHERE tm.user_id = ?",
        user_id, as: String
      )
      
      domains = (results.to_a + team_domains.to_a).uniq
      
      # Always include default domain
      domains << DEFAULT_DOMAIN unless domains.includes?(DEFAULT_DOMAIN)
      
      domains
    end
  end

  private def self.get_domain_id(domain : String) : Int32
    DB.open(DAB::DB_PATH) do |db|
      db.query_one(
        "SELECT id FROM domains WHERE domain = ?",
        domain, as: Int32
      )
    end
  rescue
    0
  end

  def to_json : String
    {
      id: @id,
      local_part: @local_part,
      domain: @domain,
      forward_to: @forward_to,
      full_email: full_email,
      active: @active,
      created_at: @created_at.to_s
    }.to_json
  end
end

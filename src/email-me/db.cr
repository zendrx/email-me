require "sqlite3"

module DB
  DATABASE = SQLite3::DB.open(ENV["DATABASE_URL"]? || "email_me.db")

  def self.setup
    # Users table
    DATABASE.exec <<-SQL
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        email TEXT UNIQUE NOT NULL,
        username TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        plan TEXT DEFAULT 'Free',
        forward_email TEXT,
        stripe_customer_id TEXT,
        created_at TIMESTAMP NOT NULL
      );
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
    SQL

    # Aliases table
    DATABASE.exec <<-SQL
      CREATE TABLE IF NOT EXISTS aliases (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        local_part TEXT NOT NULL,
        domain TEXT NOT NULL,
        forward_to TEXT NOT NULL,
        active BOOLEAN DEFAULT TRUE,
        created_at TIMESTAMP NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id),
        UNIQUE(local_part, domain)
      );
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_aliases_user_id ON aliases(user_id);
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_aliases_email ON aliases(local_part, domain);
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_aliases_active ON aliases(active);
    SQL

    # Domains table
    DATABASE.exec <<-SQL
      CREATE TABLE IF NOT EXISTS domains (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        domain TEXT UNIQUE NOT NULL,
        owner_id INTEGER NOT NULL,
        verified BOOLEAN DEFAULT FALSE,
        dns_verified_at TIMESTAMP,
        created_at TIMESTAMP NOT NULL,
        FOREIGN KEY (owner_id) REFERENCES users(id)
      );
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_domains_owner_id ON domains(owner_id);
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_domains_domain ON domains(domain);
    SQL

    # Team members table
    DATABASE.exec <<-SQL
      CREATE TABLE IF NOT EXISTS team_members (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        domain_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        role TEXT NOT NULL DEFAULT 'member',
        invited_by INTEGER NOT NULL,
        created_at TIMESTAMP NOT NULL,
        FOREIGN KEY (domain_id) REFERENCES domains(id),
        FOREIGN KEY (user_id) REFERENCES users(id),
        FOREIGN KEY (invited_by) REFERENCES users(id),
        UNIQUE(domain_id, user_id)
      );
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_team_members_domain_id ON team_members(domain_id);
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_team_members_user_id ON team_members(user_id);
    SQL

    # Cloudflare rules mapping table (store rule IDs for sync)
    DATABASE.exec <<-SQL
      CREATE TABLE IF NOT EXISTS cloudflare_rules (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        alias_id INTEGER NOT NULL,
        rule_id TEXT NOT NULL,
        created_at TIMESTAMP NOT NULL,
        FOREIGN KEY (alias_id) REFERENCES aliases(id),
        UNIQUE(alias_id)
      );
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_cf_rules_alias_id ON cloudflare_rules(alias_id);
    SQL

    # Payment transactions table
    DATABASE.exec <<-SQL
      CREATE TABLE IF NOT EXISTS transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        reference TEXT UNIQUE NOT NULL,
        amount INTEGER NOT NULL,
        plan TEXT NOT NULL,
        status TEXT NOT NULL,
        paid_at TIMESTAMP,
        created_at TIMESTAMP NOT NULL,
        FOREIGN KEY (user_id) REFERENCES users(id)
      );
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_transactions_user_id ON transactions(user_id);
    SQL

    DATABASE.exec <<-SQL
      CREATE INDEX IF NOT EXISTS idx_transactions_reference ON transactions(reference);
    SQL

    puts "Database setup complete"
  end

  # User methods
  def self.email_exists?(email : String) : Bool
    result = DATABASE.query_one?("SELECT 1 FROM users WHERE email = $1 LIMIT 1", email, as: Int32)
    !result.nil?
  end

  def self.username_exists?(username : String) : Bool
    result = DATABASE.query_one?("SELECT 1 FROM users WHERE username = $1 LIMIT 1", username, as: Int32)
    !result.nil?
  end

  def self.create_user(email : String, username : String, password_hash : String) : Int32
    DATABASE.exec(
      "INSERT INTO users (email, username, password_hash, created_at) VALUES ($1, $2, $3, $4)",
      email, username, password_hash, Time.utc
    )
    DATABASE.scalar("SELECT last_insert_rowid()", as: Int32)
  end

  def self.find_user(email_or_username : String)
    result = DATABASE.query_one?(
      "SELECT id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at 
       FROM users WHERE email = $1 OR username = $1 LIMIT 1",
      email_or_username, as: {Int32, String, String, String, String?, String?, String?, Time}
    )
    
    return nil if result.nil?
    
    id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at = result
    {
      id: id,
      email: email,
      username: username,
      password_hash: password_hash,
      plan: plan || "Free",
      forward_email: forward_email,
      stripe_customer_id: stripe_customer_id,
      created_at: created_at
    }
  end

  def self.find_user_by_id(id : Int32)
    result = DATABASE.query_one?(
      "SELECT id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at 
       FROM users WHERE id = $1 LIMIT 1",
      id, as: {Int32, String, String, String, String?, String?, String?, Time}
    )
    
    return nil if result.nil?
    
    id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at = result
    {
      id: id,
      email: email,
      username: username,
      password_hash: password_hash,
      plan: plan || "Free",
      forward_email: forward_email,
      stripe_customer_id: stripe_customer_id,
      created_at: created_at
    }
  end

  def self.find_user_by_email(email : String)
    result = DATABASE.query_one?(
      "SELECT id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at 
       FROM users WHERE email = $1 LIMIT 1",
      email, as: {Int32, String, String, String, String?, String?, String?, Time}
    )
    
    return nil if result.nil?
    
    id, email, username, password_hash, plan, forward_email, stripe_customer_id, created_at = result
    {
      id: id,
      email: email,
      username: username,
      password_hash: password_hash,
      plan: plan || "Free",
      forward_email: forward_email,
      stripe_customer_id: stripe_customer_id,
      created_at: created_at
    }
  end

  def self.update_user_plan(user_id : Int32, plan : String)
    DATABASE.exec("UPDATE users SET plan = $1 WHERE id = $2", plan, user_id)
  end

  def self.update_user_forward_email(user_id : Int32, forward_email : String)
    DATABASE.exec("UPDATE users SET forward_email = $1 WHERE id = $2", forward_email, user_id)
  end

  def self.update_user_stripe_customer_id(user_id : Int32, customer_id : String)
    DATABASE.exec("UPDATE users SET stripe_customer_id = $1 WHERE id = $2", customer_id, user_id)
  end

  def self.delete_user(user_id : Int32)
    # Delete all related records first
    DATABASE.exec("DELETE FROM cloudflare_rules WHERE alias_id IN (SELECT id FROM aliases WHERE user_id = $1)", user_id)
    DATABASE.exec("DELETE FROM aliases WHERE user_id = $1", user_id)
    DATABASE.exec("DELETE FROM team_members WHERE user_id = $1", user_id)
    DATABASE.exec("DELETE FROM domains WHERE owner_id = $1", user_id)
    DATABASE.exec("DELETE FROM transactions WHERE user_id = $1", user_id)
    DATABASE.exec("DELETE FROM users WHERE id = $1", user_id)
  end

  # Alias methods
  def self.create_alias(user_id : Int32, local_part : String, domain : String, forward_to : String, created_at : Time) : Int32
    DATABASE.exec(
      "INSERT INTO aliases (user_id, local_part, domain, forward_to, created_at) VALUES ($1, $2, $3, $4, $5)",
      user_id, local_part, domain, forward_to, created_at
    )
    DATABASE.scalar("SELECT last_insert_rowid()", as: Int32)
  end

  def self.get_aliases_by_user(user_id : Int32, active_only : Bool = true) : Array({Int32, String, String, String, Bool, Time})
    query = "SELECT id, local_part, domain, forward_to, active, created_at FROM aliases WHERE user_id = $1"
    query += " AND active = true" if active_only
    
    DATABASE.query_all(query, user_id, as: {Int32, String, String, String, Bool, Time})
  end

  def self.get_alias_by_id(alias_id : Int32)
    result = DATABASE.query_one?(
      "SELECT id, user_id, local_part, domain, forward_to, active, created_at FROM aliases WHERE id = $1",
      alias_id, as: {Int32, Int32, String, String, String, Bool, Time}
    )
    
    return nil if result.nil?
    
    id, user_id, local_part, domain, forward_to, active, created_at = result
    {
      id: id,
      user_id: user_id,
      local_part: local_part,
      domain: domain,
      forward_to: forward_to,
      active: active,
      created_at: created_at
    }
  end

  def self.get_alias_by_email(local_part : String, domain : String)
    result = DATABASE.query_one?(
      "SELECT id, user_id, local_part, domain, forward_to, active, created_at FROM aliases WHERE local_part = $1 AND domain = $2 AND active = true",
      local_part, domain, as: {Int32, Int32, String, String, String, Bool, Time}
    )
    
    return nil if result.nil?
    
    id, user_id, local_part, domain, forward_to, active, created_at = result
    {
      id: id,
      user_id: user_id,
      local_part: local_part,
      domain: domain,
      forward_to: forward_to,
      active: active,
      created_at: created_at
    }
  end

  def self.deactivate_alias(alias_id : Int32)
    DATABASE.exec("UPDATE aliases SET active = false WHERE id = $1", alias_id)
  end

  def self.alias_exists?(local_part : String, domain : String) : Bool
    result = DATABASE.query_one?("SELECT 1 FROM aliases WHERE local_part = $1 AND domain = $2 AND active = true LIMIT 1", local_part, domain, as: Int32)
    !result.nil?
  end

  # Domain methods
  def self.create_domain(domain : String, owner_id : Int32, created_at : Time) : Int32
    DATABASE.exec(
      "INSERT INTO domains (domain, owner_id, created_at) VALUES ($1, $2, $3)",
      domain, owner_id, created_at
    )
    DATABASE.scalar("SELECT last_insert_rowid()", as: Int32)
  end

  def self.get_domain_by_name(domain : String)
    result = DATABASE.query_one?(
      "SELECT id, domain, owner_id, verified, dns_verified_at, created_at FROM domains WHERE domain = $1",
      domain, as: {Int32, String, Int32, Bool, Time?, Time}
    )
    
    return nil if result.nil?
    
    id, domain, owner_id, verified, dns_verified_at, created_at = result
    {
      id: id,
      domain: domain,
      owner_id: owner_id,
      verified: verified,
      dns_verified_at: dns_verified_at,
      created_at: created_at
    }
  end

  def self.get_domains_by_owner(owner_id : Int32) : Array({Int32, String, Bool, Time})
    DATABASE.query_all(
      "SELECT id, domain, verified, created_at FROM domains WHERE owner_id = $1",
      owner_id, as: {Int32, String, Bool, Time}
    )
  end

  def self.verify_domain(domain_id : Int32)
    DATABASE.exec(
      "UPDATE domains SET verified = true, dns_verified_at = $1 WHERE id = $2",
      Time.utc, domain_id
    )
  end

  # Team member methods
  def self.add_team_member(domain_id : Int32, user_id : Int32, invited_by : Int32, role : String = "member", created_at : Time = Time.utc)
    DATABASE.exec(
      "INSERT INTO team_members (domain_id, user_id, role, invited_by, created_at) VALUES ($1, $2, $3, $4, $5)",
      domain_id, user_id, role, invited_by, created_at
    )
  end

  def self.get_team_members(domain_id : Int32) : Array({Int32, String, String, Time})
    DATABASE.query_all(
      "SELECT tm.user_id, tm.role, u.email, tm.created_at 
       FROM team_members tm
       JOIN users u ON u.id = tm.user_id
       WHERE tm.domain_id = $1",
      domain_id, as: {Int32, String, String, Time}
    )
  end

  def self.is_team_member?(domain_id : Int32, user_id : Int32) : Bool
    result = DATABASE.query_one?(
      "SELECT 1 FROM team_members WHERE domain_id = $1 AND user_id = $2 LIMIT 1",
      domain_id, user_id, as: Int32
    )
    !result.nil?
  end

  def self.remove_team_member(domain_id : Int32, user_id : Int32)
    DATABASE.exec("DELETE FROM team_members WHERE domain_id = $1 AND user_id = $2", domain_id, user_id)
  end

  # Cloudflare rule methods
  def self.save_cloudflare_rule(alias_id : Int32, rule_id : String, created_at : Time = Time.utc)
    DATABASE.exec(
      "INSERT INTO cloudflare_rules (alias_id, rule_id, created_at) VALUES ($1, $2, $3)",
      alias_id, rule_id, created_at
    )
  end

  def self.get_cloudflare_rule_id(alias_id : Int32) : String?
    result = DATABASE.query_one?("SELECT rule_id FROM cloudflare_rules WHERE alias_id = $1", alias_id, as: String)
    result
  end

  def self.delete_cloudflare_rule(alias_id : Int32)
    DATABASE.exec("DELETE FROM cloudflare_rules WHERE alias_id = $1", alias_id)
  end

  # Transaction methods
  def self.save_transaction(user_id : Int32, reference : String, amount : Int32, plan : String, status : String, created_at : Time = Time.utc)
    DATABASE.exec(
      "INSERT INTO transactions (user_id, reference, amount, plan, status, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
      user_id, reference, amount, plan, status, created_at
    )
  end

  def self.update_transaction_status(reference : String, status : String, paid_at : Time? = nil)
    if paid_at
      DATABASE.exec("UPDATE transactions SET status = $1, paid_at = $2 WHERE reference = $3", status, paid_at, reference)
    else
      DATABASE.exec("UPDATE transactions SET status = $1 WHERE reference = $2", status, reference)
    end
  end

  def self.get_transaction(reference : String)
    result = DATABASE.query_one?(
      "SELECT id, user_id, reference, amount, plan, status, paid_at, created_at FROM transactions WHERE reference = $1",
      reference, as: {Int32, Int32, String, Int32, String, String, Time?, Time}
    )
    
    return nil if result.nil?
    
    id, user_id, reference, amount, plan, status, paid_at, created_at = result
    {
      id: id,
      user_id: user_id,
      reference: reference,
      amount: amount,
      plan: plan,
      status: status,
      paid_at: paid_at,
      created_at: created_at
    }
  end
end

# Run setup when file loads
DB.setup

require "pg"

module EmailMe
  module DB
    extend self

    @@db : PG::Connection? = nil

    def connection
      @@db ||= PG.connect(ENV["DATABASE_URL"])
    end

    def init
      conn = connection
      conn.exec("
        CREATE TABLE IF NOT EXISTS users (
          id SERIAL PRIMARY KEY,
          email TEXT NOT NULL,
          password_hash TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      ")
      conn.exec("
        CREATE TABLE IF NOT EXISTS aliases (
          id SERIAL PRIMARY KEY,
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          alias TEXT NOT NULL,
          domain TEXT NOT NULL,
          target_email TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      ")
      conn.exec("
        CREATE TABLE IF NOT EXISTS domains (
          id SERIAL PRIMARY KEY,
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          domain TEXT NOT NULL,
          verified BOOLEAN DEFAULT FALSE,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      ")
      conn.exec("
        CREATE TABLE IF NOT EXISTS teams (
          id SERIAL PRIMARY KEY,
          name TEXT NOT NULL,
          owner_id INTEGER NOT NULL REFERENCES users(id),
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      ")
      conn.exec("
        CREATE TABLE IF NOT EXISTS team_members (
          id SERIAL PRIMARY KEY,
          team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          role TEXT NOT NULL DEFAULT 'member',
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      ")
      conn.exec("
        CREATE TABLE IF NOT EXISTS payments (
          id SERIAL PRIMARY KEY,
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          amount INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending',
          reference TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      ")
      conn.exec("
        CREATE TABLE IF NOT EXISTS configs (
          id SERIAL PRIMARY KEY,
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          key TEXT NOT NULL,
          value TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
      ")
    end

    # User methods
    def create_user(email : String, password_hash : String)
      connection.exec("
        INSERT INTO users (email, password_hash)
        VALUES ($1, $2)
        RETURNING id
      ", email, password_hash)
    end

    def find_user_by_email(email : String)
      connection.query_one?("
        SELECT id, email, password_hash, created_at, updated_at
        FROM users
        WHERE email = $1
        LIMIT 1
      ", email, as: {Int32, String, String, Time, Time})
    end

    def find_user_by_id(id : Int32)
      connection.query_one?("
        SELECT id, email, password_hash, created_at, updated_at
        FROM users
        WHERE id = $1
        LIMIT 1
      ", id, as: {Int32, String, String, Time, Time})
    end

    # Alias methods
    def create_alias(user_id : Int32, alias : String, domain : String, target_email : String)
      connection.exec("
        INSERT INTO aliases (user_id, alias, domain, target_email)
        VALUES ($1, $2, $3, $4)
        RETURNING id
      ", user_id, alias, domain, target_email)
    end

    def find_aliases_by_user(user_id : Int32)
      connection.query_all("
        SELECT id, user_id, alias, domain, target_email, created_at, updated_at
        FROM aliases
        WHERE user_id = $1
      ", user_id, as: {Int32, Int32, String, String, String, Time, Time})
    end

    def find_alias_by_email(alias : String, domain : String)
      connection.query_one?("
        SELECT id, user_id, alias, domain, target_email, created_at, updated_at
        FROM aliases
        WHERE alias = $1 AND domain = $2
        LIMIT 1
      ", alias, domain, as: {Int32, Int32, String, String, String, Time, Time})
    end

    def delete_alias(id : Int32)
      connection.exec("DELETE FROM aliases WHERE id = $1", id)
    end

    # Domain methods
    def create_domain(user_id : Int32, domain : String)
      connection.exec("
        INSERT INTO domains (user_id, domain)
        VALUES ($1, $2)
        RETURNING id
      ", user_id, domain)
    end

    def find_domains_by_user(user_id : Int32)
      connection.query_all("
        SELECT id, user_id, domain, verified, created_at, updated_at
        FROM domains
        WHERE user_id = $1
      ", user_id, as: {Int32, Int32, String, Bool, Time, Time})
    end

    def verify_domain(id : Int32)
      connection.exec("UPDATE domains SET verified = TRUE WHERE id = $1", id)
    end

    def delete_domain(id : Int32)
      connection.exec("DELETE FROM domains WHERE id = $1", id)
    end

    # Team methods
    def create_team(name : String, owner_id : Int32)
      connection.exec("
        INSERT INTO teams (name, owner_id)
        VALUES ($1, $2)
        RETURNING id
      ", name, owner_id)
    end

    def find_team_by_id(id : Int32)
      connection.query_one?("
        SELECT id, name, owner_id, created_at, updated_at
        FROM teams
        WHERE id = $1
        LIMIT 1
      ", id, as: {Int32, String, Int32, Time, Time})
    end

    def find_teams_by_user(user_id : Int32)
      connection.query_all("
        SELECT t.id, t.name, t.owner_id, t.created_at, t.updated_at
        FROM teams t
        JOIN team_members tm ON t.id = tm.team_id
        WHERE tm.user_id = $1
      ", user_id, as: {Int32, String, Int32, Time, Time})
    end

    def add_team_member(team_id : Int32, user_id : Int32, role : String = "member")
      connection.exec("
        INSERT INTO team_members (team_id, user_id, role)
        VALUES ($1, $2, $3)
        RETURNING id
      ", team_id, user_id, role)
    end

    def find_team_members(team_id : Int32)
      connection.query_all("
        SELECT tm.id, tm.team_id, tm.user_id, tm.role, tm.created_at, tm.updated_at,
               u.email
        FROM team_members tm
        JOIN users u ON tm.user_id = u.id
        WHERE tm.team_id = $1
      ", team_id, as: {Int32, Int32, Int32, String, Time, Time, String})
    end

    def remove_team_member(team_id : Int32, user_id : Int32)
      connection.exec("
        DELETE FROM team_members
        WHERE team_id = $1 AND user_id = $2
      ", team_id, user_id)
    end

    # Payment methods
    def create_payment(user_id : Int32, amount : Int32, reference : String)
      connection.exec("
        INSERT INTO payments (user_id, amount, reference)
        VALUES ($1, $2, $3)
        RETURNING id
      ", user_id, amount, reference)
    end

    def find_payment_by_reference(reference : String)
      connection.query_one?("
        SELECT id, user_id, amount, status, reference, created_at, updated_at
        FROM payments
        WHERE reference = $1
        LIMIT 1
      ", reference, as: {Int32, Int32, Int32, String, String, Time, Time})
    end

    def update_payment_status(id : Int32, status : String)
      connection.exec("
        UPDATE payments
        SET status = $1, updated_at = CURRENT_TIMESTAMP
        WHERE id = $2
      ", status, id)
    end

    def find_payments_by_user(user_id : Int32)
      connection.query_all("
        SELECT id, user_id, amount, status, reference, created_at, updated_at
        FROM payments
        WHERE user_id = $1
      ", user_id, as: {Int32, Int32, Int32, String, String, Time, Time})
    end

    # Config methods
    def set_config(user_id : Int32, key : String, value : String)
      connection.exec("
        INSERT INTO configs (user_id, key, value)
        VALUES ($1, $2, $3)
        ON CONFLICT (user_id, key) DO UPDATE
        SET value = $3, updated_at = CURRENT_TIMESTAMP
        RETURNING id
      ", user_id, key, value)
    end

    def get_config(user_id : Int32, key : String)
      connection.query_one?("
        SELECT id, user_id, key, value, created_at, updated_at
        FROM configs
        WHERE user_id = $1 AND key = $2
        LIMIT 1
      ", user_id, key, as: {Int32, Int32, String, String, Time, Time})
    end

    def delete_config(user_id : Int32, key : String)
      connection.exec("
        DELETE FROM configs
        WHERE user_id = $1 AND key = $2
      ", user_id, key)
    end

    # Stats
    def count_aliases_by_user(user_id : Int32)
      connection.query_one("
        SELECT COUNT(*) FROM aliases WHERE user_id = $1
      ", user_id, as: Int64)
    end

    def count_domains_by_user(user_id : Int32)
      connection.query_one("
        SELECT COUNT(*) FROM domains WHERE user_id = $1
      ", user_id, as: Int64)
    end

    def count_teams_by_user(user_id : Int32)
      connection.query_one("
        SELECT COUNT(*) FROM team_members WHERE user_id = $1
      ", user_id, as: Int64)
    end

    # Close connection
    def close
      @@db.try &.close
      @@db = nil
    end
  end
end

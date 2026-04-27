export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      attachments: {
        Row: {
          created_at: string
          file_name: string
          id: string
          line_item_id: string
          mime_type: string
          size_bytes: number
          storage_path: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          file_name: string
          id?: string
          line_item_id: string
          mime_type: string
          size_bytes: number
          storage_path: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          file_name?: string
          id?: string
          line_item_id?: string
          mime_type?: string
          size_bytes?: number
          storage_path?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "attachments_line_item_id_fkey"
            columns: ["line_item_id"]
            isOneToOne: false
            referencedRelation: "line_items"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log: {
        Row: {
          action: string
          created_at: string
          entity_id: string | null
          entity_type: string
          id: string
          ip_address: string | null
          metadata: Json | null
          user_id: string | null
        }
        Insert: {
          action: string
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: string
          ip_address?: string | null
          metadata?: Json | null
          user_id?: string | null
        }
        Update: {
          action?: string
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: string
          ip_address?: string | null
          metadata?: Json | null
          user_id?: string | null
        }
        Relationships: []
      }
      currencies: {
        Row: {
          active: boolean
          code: string
          created_at: string
          id: string
          name: string
          symbol: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          code: string
          created_at?: string
          id?: string
          name: string
          symbol: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          code?: string
          created_at?: string
          id?: string
          name?: string
          symbol?: string
          updated_at?: string
        }
        Relationships: []
      }
      department_heads: {
        Row: {
          created_at: string
          department_id: string
          employee_id: string
          from_date: string
          id: string
          to_date: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          department_id: string
          employee_id: string
          from_date: string
          id?: string
          to_date?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          department_id?: string
          employee_id?: string
          from_date?: string
          id?: string
          to_date?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "department_heads_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "department_heads_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      departments: {
        Row: {
          created_at: string
          deleted_at: string | null
          dept_id: string
          id: string
          name: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          dept_id: string
          id?: string
          name: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          dept_id?: string
          id?: string
          name?: string
          updated_at?: string
        }
        Relationships: []
      }
      emergency_contacts: {
        Row: {
          alt_phone: string | null
          created_at: string
          email: string | null
          employee_id: string
          id: string
          name: string
          phone: string | null
          relationship: string | null
          updated_at: string
        }
        Insert: {
          alt_phone?: string | null
          created_at?: string
          email?: string | null
          employee_id: string
          id?: string
          name: string
          phone?: string | null
          relationship?: string | null
          updated_at?: string
        }
        Update: {
          alt_phone?: string | null
          created_at?: string
          email?: string | null
          employee_id?: string
          id?: string
          name?: string
          phone?: string | null
          relationship?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "emergency_contacts_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      employee_addresses: {
        Row: {
          city: string | null
          country: string | null
          created_at: string
          district: string | null
          employee_id: string
          id: string
          landmark: string | null
          line1: string | null
          line2: string | null
          pin: string | null
          state: string | null
          updated_at: string
        }
        Insert: {
          city?: string | null
          country?: string | null
          created_at?: string
          district?: string | null
          employee_id: string
          id?: string
          landmark?: string | null
          line1?: string | null
          line2?: string | null
          pin?: string | null
          state?: string | null
          updated_at?: string
        }
        Update: {
          city?: string | null
          country?: string | null
          created_at?: string
          district?: string | null
          employee_id?: string
          id?: string
          landmark?: string | null
          line1?: string | null
          line2?: string | null
          pin?: string | null
          state?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_addresses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      employees: {
        Row: {
          base_currency_id: string | null
          business_email: string | null
          country_code: string | null
          created_at: string
          deleted_at: string | null
          dept_id: string | null
          designation: string | null
          employee_id: string
          end_date: string | null
          hire_date: string | null
          id: string
          job_title: string | null
          manager_id: string | null
          marital_status: string | null
          mobile: string | null
          name: string
          nationality: string | null
          personal_email: string | null
          photo_url: string | null
          probation_end_date: string | null
          status: Database["public"]["Enums"]["employee_status"]
          updated_at: string
          work_country: string | null
          work_location: string | null
        }
        Insert: {
          base_currency_id?: string | null
          business_email?: string | null
          country_code?: string | null
          created_at?: string
          deleted_at?: string | null
          dept_id?: string | null
          designation?: string | null
          employee_id: string
          end_date?: string | null
          hire_date?: string | null
          id?: string
          job_title?: string | null
          manager_id?: string | null
          marital_status?: string | null
          mobile?: string | null
          name: string
          nationality?: string | null
          personal_email?: string | null
          photo_url?: string | null
          probation_end_date?: string | null
          status?: Database["public"]["Enums"]["employee_status"]
          updated_at?: string
          work_country?: string | null
          work_location?: string | null
        }
        Update: {
          base_currency_id?: string | null
          business_email?: string | null
          country_code?: string | null
          created_at?: string
          deleted_at?: string | null
          dept_id?: string | null
          designation?: string | null
          employee_id?: string
          end_date?: string | null
          hire_date?: string | null
          id?: string
          job_title?: string | null
          manager_id?: string | null
          marital_status?: string | null
          mobile?: string | null
          name?: string
          nationality?: string | null
          personal_email?: string | null
          photo_url?: string | null
          probation_end_date?: string | null
          status?: Database["public"]["Enums"]["employee_status"]
          updated_at?: string
          work_country?: string | null
          work_location?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employees_base_currency_id_fkey"
            columns: ["base_currency_id"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_dept_id_fkey"
            columns: ["dept_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      exchange_rates: {
        Row: {
          created_at: string
          effective_date: string
          from_currency_id: string
          id: string
          rate: number
          to_currency_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          effective_date: string
          from_currency_id: string
          id?: string
          rate: number
          to_currency_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          effective_date?: string
          from_currency_id?: string
          id?: string
          rate?: number
          to_currency_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "exchange_rates_from_currency_id_fkey"
            columns: ["from_currency_id"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "exchange_rates_to_currency_id_fkey"
            columns: ["to_currency_id"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["id"]
          },
        ]
      }
      expense_reports: {
        Row: {
          approved_at: string | null
          approved_by: string | null
          base_currency_id: string
          created_at: string
          deleted_at: string | null
          employee_id: string
          id: string
          name: string
          rejected_at: string | null
          rejected_by: string | null
          rejection_reason: string | null
          status: Database["public"]["Enums"]["expense_status"]
          submitted_at: string | null
          updated_at: string
        }
        Insert: {
          approved_at?: string | null
          approved_by?: string | null
          base_currency_id: string
          created_at?: string
          deleted_at?: string | null
          employee_id: string
          id?: string
          name: string
          rejected_at?: string | null
          rejected_by?: string | null
          rejection_reason?: string | null
          status?: Database["public"]["Enums"]["expense_status"]
          submitted_at?: string | null
          updated_at?: string
        }
        Update: {
          approved_at?: string | null
          approved_by?: string | null
          base_currency_id?: string
          created_at?: string
          deleted_at?: string | null
          employee_id?: string
          id?: string
          name?: string
          rejected_at?: string | null
          rejected_by?: string | null
          rejection_reason?: string | null
          status?: Database["public"]["Enums"]["expense_status"]
          submitted_at?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "expense_reports_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_reports_base_currency_id_fkey"
            columns: ["base_currency_id"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_reports_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_reports_rejected_by_fkey"
            columns: ["rejected_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      identity_records: {
        Row: {
          country: string | null
          created_at: string
          employee_id: string
          expiry: string | null
          id: string
          id_number: string | null
          id_type: string | null
          record_type: string | null
          updated_at: string
        }
        Insert: {
          country?: string | null
          created_at?: string
          employee_id: string
          expiry?: string | null
          id?: string
          id_number?: string | null
          id_type?: string | null
          record_type?: string | null
          updated_at?: string
        }
        Update: {
          country?: string | null
          created_at?: string
          employee_id?: string
          expiry?: string | null
          id?: string
          id_number?: string | null
          id_type?: string | null
          record_type?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "identity_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      line_items: {
        Row: {
          amount: number
          category_id: string | null
          converted_amount: number
          created_at: string
          currency_id: string
          deleted_at: string | null
          exchange_rate_id: string | null
          exchange_rate_snapshot: number | null
          expense_date: string
          id: string
          note: string | null
          project_id: string | null
          report_id: string
          updated_at: string
        }
        Insert: {
          amount: number
          category_id?: string | null
          converted_amount: number
          created_at?: string
          currency_id: string
          deleted_at?: string | null
          exchange_rate_id?: string | null
          exchange_rate_snapshot?: number | null
          expense_date: string
          id?: string
          note?: string | null
          project_id?: string | null
          report_id: string
          updated_at?: string
        }
        Update: {
          amount?: number
          category_id?: string | null
          converted_amount?: number
          created_at?: string
          currency_id?: string
          deleted_at?: string | null
          exchange_rate_id?: string | null
          exchange_rate_snapshot?: number | null
          expense_date?: string
          id?: string
          note?: string | null
          project_id?: string | null
          report_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "line_items_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "picklist_values"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "line_items_currency_id_fkey"
            columns: ["currency_id"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "line_items_exchange_rate_id_fkey"
            columns: ["exchange_rate_id"]
            isOneToOne: false
            referencedRelation: "exchange_rates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "line_items_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "projects"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "line_items_report_id_fkey"
            columns: ["report_id"]
            isOneToOne: false
            referencedRelation: "expense_reports"
            referencedColumns: ["id"]
          },
        ]
      }
      notifications: {
        Row: {
          body: string | null
          created_at: string
          entity_id: string | null
          entity_type: string | null
          id: string
          read_at: string | null
          title: string
          type: string
          updated_at: string
          user_id: string
        }
        Insert: {
          body?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string | null
          id?: string
          read_at?: string | null
          title: string
          type: string
          updated_at?: string
          user_id: string
        }
        Update: {
          body?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string | null
          id?: string
          read_at?: string | null
          title?: string
          type?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      passports: {
        Row: {
          country: string | null
          created_at: string
          employee_id: string
          expiry_date: string | null
          id: string
          issue_date: string | null
          passport_number: string | null
          updated_at: string
        }
        Insert: {
          country?: string | null
          created_at?: string
          employee_id: string
          expiry_date?: string | null
          id?: string
          issue_date?: string | null
          passport_number?: string | null
          updated_at?: string
        }
        Update: {
          country?: string | null
          created_at?: string
          employee_id?: string
          expiry_date?: string | null
          id?: string
          issue_date?: string | null
          passport_number?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "passports_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      picklist_values: {
        Row: {
          active: boolean
          created_at: string
          id: string
          parent_value_id: string | null
          picklist_id: string
          ref_id: string | null
          updated_at: string
          value: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id?: string
          parent_value_id?: string | null
          picklist_id: string
          ref_id?: string | null
          updated_at?: string
          value: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          parent_value_id?: string | null
          picklist_id?: string
          ref_id?: string | null
          updated_at?: string
          value?: string
        }
        Relationships: [
          {
            foreignKeyName: "picklist_values_parent_value_id_fkey"
            columns: ["parent_value_id"]
            isOneToOne: false
            referencedRelation: "picklist_values"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "picklist_values_picklist_id_fkey"
            columns: ["picklist_id"]
            isOneToOne: false
            referencedRelation: "picklists"
            referencedColumns: ["id"]
          },
        ]
      }
      picklists: {
        Row: {
          created_at: string
          id: string
          name: string
          picklist_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          picklist_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          picklist_id?: string
          updated_at?: string
        }
        Relationships: []
      }
      // profile_roles table has been dropped in Phase E of the role architecture migration.
      // Roles are now managed exclusively via user_roles → roles.code.
      profiles: {
        Row: {
          created_at: string
          employee_id: string | null
          id: string
          is_active: boolean
          updated_at: string
        }
        Insert: {
          created_at?: string
          employee_id?: string | null
          id: string
          is_active?: boolean
          updated_at?: string
        }
        Update: {
          created_at?: string
          employee_id?: string | null
          id?: string
          is_active?: boolean
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "profiles_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
        ]
      }
      projects: {
        Row: {
          active: boolean
          created_at: string
          end_date: string | null
          id: string
          name: string
          start_date: string | null
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          end_date?: string | null
          id?: string
          name: string
          start_date?: string | null
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          end_date?: string | null
          id?: string
          name?: string
          start_date?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      // ─── Permission system tables (Phase 1) ──────────────────────────────────
      modules: {
        Row: {
          id:         string
          code:       string
          name:       string
          active:     boolean
          sort_order: number
          created_at: string
          updated_at: string
        }
        Insert: {
          id?:         string
          code:        string
          name:        string
          active?:     boolean
          sort_order?: number
          created_at?: string
          updated_at?: string
        }
        Update: {
          id?:         string
          code?:       string
          name?:       string
          active?:     boolean
          sort_order?: number
          created_at?: string
          updated_at?: string
        }
        Relationships: []
      }
      roles: {
        Row: {
          id:          string
          code:        string
          name:        string
          description: string | null
          is_system:   boolean
          /** 'system' = auto-managed, 'custom' = admin-managed, 'protected' = admin with guardrails */
          role_type:   'system' | 'custom' | 'protected'
          created_at:  string
          updated_at:  string
        }
        Insert: {
          id?:          string
          code:         string
          name:         string
          description?: string | null
          is_system?:   boolean
          role_type?:   'system' | 'custom' | 'protected'
          created_at?:  string
          updated_at?:  string
        }
        Update: {
          id?:          string
          code?:        string
          name?:        string
          description?: string | null
          is_system?:   boolean
          role_type?:   'system' | 'custom' | 'protected'
          created_at?:  string
          updated_at?:  string
        }
        Relationships: []
      }
      permissions: {
        Row: {
          id:          string
          module_id:   string | null
          code:        string
          name:        string
          description: string | null
          created_at:  string
        }
        Insert: {
          id?:          string
          module_id?:   string | null
          code:         string
          name:         string
          description?: string | null
          created_at?:  string
        }
        Update: {
          id?:          string
          module_id?:   string | null
          code?:        string
          name?:        string
          description?: string | null
          created_at?:  string
        }
        Relationships: [
          {
            foreignKeyName: "permissions_module_id_fkey"
            columns: ["module_id"]
            isOneToOne: false
            referencedRelation: "modules"
            referencedColumns: ["id"]
          }
        ]
      }
      role_permissions: {
        Row: {
          role_id:       string
          permission_id: string
          created_at:    string
        }
        Insert: {
          role_id:       string
          permission_id: string
          created_at?:   string
        }
        Update: {
          role_id?:       string
          permission_id?: string
          created_at?:    string
        }
        Relationships: [
          {
            foreignKeyName: "role_permissions_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "role_permissions_permission_id_fkey"
            columns: ["permission_id"]
            isOneToOne: false
            referencedRelation: "permissions"
            referencedColumns: ["id"]
          }
        ]
      }
      user_roles: {
        Row: {
          id:                string
          profile_id:        string
          role_id:           string
          granted_by:        string | null
          granted_at:        string
          is_active:         boolean
          expires_at:        string | null
          updated_at:        string
          assignment_source: 'manual' | 'system'
        }
        Insert: {
          id?:                string
          profile_id:         string
          role_id:            string
          granted_by?:        string | null
          granted_at?:        string
          is_active?:         boolean
          expires_at?:        string | null
          updated_at?:        string
          assignment_source?: 'manual' | 'system'
        }
        Update: {
          id?:                string
          profile_id?:        string
          role_id?:           string
          granted_by?:        string | null
          granted_at?:        string
          is_active?:         boolean
          expires_at?:        string | null
          updated_at?:        string
          assignment_source?: 'manual' | 'system'
        }
        Relationships: [
          {
            foreignKeyName: "user_roles_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_roles_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          }
        ]
      }
      // ─── End permission system tables ─────────────────────────────────────────
      workflow_instances: {
        Row: {
          created_at: string
          current_step: string | null
          entity_id: string
          entity_type: string
          id: string
          status: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          current_step?: string | null
          entity_id: string
          entity_type?: string
          id?: string
          status?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          current_step?: string | null
          entity_id?: string
          entity_type?: string
          id?: string
          status?: string
          updated_at?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      get_my_employee_id: { Args: Record<PropertyKey, never>; Returns: string }
      /**
       * Returns all permission codes held by the current user.
       * Joins user_roles → role_permissions → permissions server-side.
       * Called once on login by PermissionContext; cached in a Set client-side.
       */
      get_my_permissions: { Args: Record<PropertyKey, never>; Returns: string[] }
      // has_role / has_any_role accept text (roles.code)
      has_any_role: {
        Args: { check_roles: string[] }
        Returns: boolean
      }
      has_role: {
        Args: { check_role: string }
        Returns: boolean
      }
      /**
       * Returns true if the current user holds the given permission code
       * via any active role assignment. Used in RLS policies.
       */
      has_permission: {
        Args: { check_permission: string }
        Returns: boolean
      }
      is_my_direct_report: { Args: { emp_id: string }; Returns: boolean }
      /** Returns true if emp_id belongs to a department the current user currently heads. */
      is_in_my_department: { Args: { emp_id: string }; Returns: boolean }
      /**
       * Reconciles user_roles for system roles (ESS / dept_head) from employee data.
       * MSS removed — Manager is now manually assigned by admin.
       */
      sync_system_roles: { Args: { p_profile_id?: string }; Returns: { synced: number; revoked: number } }
      // ── Phase 2: Workflow state machine RPCs ────────────────────────────────
      /** ESS: transitions own draft report → submitted. */
      submit_expense: { Args: { p_report_id: string }; Returns: void }
      /**
       * Two-stage approval:
       *   Manager/DeptHead  submitted       → manager_approved
       *   Finance/Admin     manager_approved → approved
       *   Admin             submitted       → approved  (skip stage 1)
       */
      approve_expense: { Args: { p_report_id: string; p_notes?: string }; Returns: void }
      /** Manager/DeptHead/Finance/Admin: transitions report → rejected. */
      reject_expense: { Args: { p_report_id: string; p_reason: string }; Returns: void }
      /** ESS: pulls back a submitted report → draft (before manager actions it). */
      recall_expense: { Args: { p_report_id: string }; Returns: void }
      /** ESS (own draft) / Admin (any draft): soft-deletes a draft expense report. */
      delete_expense_report: { Args: { p_report_id: string }; Returns: void }
    }
    Enums: {
      employee_status: "Draft" | "Incomplete" | "Active" | "Inactive"
      expense_status: "draft" | "submitted" | "manager_approved" | "approved" | "rejected"
      // role_type enum removed — roles are now identified by roles.code (text)
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      employee_status: ["Draft", "Incomplete", "Active", "Inactive"],
      expense_status: ["draft", "submitted", "approved", "rejected"],
      role_type: ["employee", "manager", "finance", "admin"],
    },
  },
} as const

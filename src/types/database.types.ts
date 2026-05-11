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
      access_scopes: {
        Row: {
          created_at: string | null
          granted_by: string | null
          id: string
          module: string
          profile_id: string | null
          scope_type: string
          scope_value: string | null
          updated_at: string | null
        }
        Insert: {
          created_at?: string | null
          granted_by?: string | null
          id?: string
          module: string
          profile_id?: string | null
          scope_type: string
          scope_value?: string | null
          updated_at?: string | null
        }
        Update: {
          created_at?: string | null
          granted_by?: string | null
          id?: string
          module?: string
          profile_id?: string | null
          scope_type?: string
          scope_value?: string | null
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "access_scopes_granted_by_fkey"
            columns: ["granted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "access_scopes_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      app_config: {
        Row: {
          description: string | null
          key: string
          value: string
        }
        Insert: {
          description?: string | null
          key: string
          value: string
        }
        Update: {
          description?: string | null
          key?: string
          value?: string
        }
        Relationships: []
      }
      attachment_deletions: {
        Row: {
          deleted_at: string
          id: string
          module_code: string | null
          record_id: string | null
          storage_path: string
        }
        Insert: {
          deleted_at?: string
          id?: string
          module_code?: string | null
          record_id?: string | null
          storage_path: string
        }
        Update: {
          deleted_at?: string
          id?: string
          module_code?: string | null
          record_id?: string | null
          storage_path?: string
        }
        Relationships: []
      }
      attachments: {
        Row: {
          created_at: string
          file_name: string
          id: string
          line_item_id: string | null
          mime_type: string
          module_code: string | null
          record_id: string | null
          size_bytes: number
          storage_path: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          file_name: string
          id?: string
          line_item_id?: string | null
          mime_type: string
          module_code?: string | null
          record_id?: string | null
          size_bytes: number
          storage_path: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          file_name?: string
          id?: string
          line_item_id?: string | null
          mime_type?: string
          module_code?: string | null
          record_id?: string | null
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
          {
            foreignKeyName: "attachments_module_code_fkey"
            columns: ["module_code"]
            isOneToOne: false
            referencedRelation: "module_codes"
            referencedColumns: ["code"]
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
          new_value: Json | null
          old_value: Json | null
          user_agent: string | null
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
          new_value?: Json | null
          old_value?: Json | null
          user_agent?: string | null
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
          new_value?: Json | null
          old_value?: Json | null
          user_agent?: string | null
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
            foreignKeyName: "department_heads_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "vw_departments_lookup"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "department_heads_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["department_id"]
          },
          {
            foreignKeyName: "department_heads_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "department_heads_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      departments: {
        Row: {
          created_at: string
          deleted_at: string | null
          dept_id: string
          end_date: string | null
          head_employee_id: string | null
          id: string
          name: string
          parent_dept_id: string | null
          start_date: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          dept_id: string
          end_date?: string | null
          head_employee_id?: string | null
          id?: string
          name: string
          parent_dept_id?: string | null
          start_date?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          dept_id?: string
          end_date?: string | null
          head_employee_id?: string | null
          id?: string
          name?: string
          parent_dept_id?: string | null
          start_date?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "departments_head_employee_id_fkey"
            columns: ["head_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_head_employee_id_fkey"
            columns: ["head_employee_id"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_parent_dept_id_fkey"
            columns: ["parent_dept_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_parent_dept_id_fkey"
            columns: ["parent_dept_id"]
            isOneToOne: false
            referencedRelation: "vw_departments_lookup"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_parent_dept_id_fkey"
            columns: ["parent_dept_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["department_id"]
          },
        ]
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
          {
            foreignKeyName: "emergency_contacts_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
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
          {
            foreignKeyName: "employee_addresses_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      employee_audit_log: {
        Row: {
          changed_at: string
          changed_by: string | null
          employee_id: string | null
          id: string
          new_data: Json | null
          old_data: Json | null
          operation: string
          record_id: string
          table_name: string
        }
        Insert: {
          changed_at?: string
          changed_by?: string | null
          employee_id?: string | null
          id?: string
          new_data?: Json | null
          old_data?: Json | null
          operation: string
          record_id: string
          table_name: string
        }
        Update: {
          changed_at?: string
          changed_by?: string | null
          employee_id?: string | null
          id?: string
          new_data?: Json | null
          old_data?: Json | null
          operation?: string
          record_id?: string
          table_name?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_audit_log_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_audit_log_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      employee_contact: {
        Row: {
          country_code: string | null
          created_at: string
          employee_id: string
          mobile: string | null
          personal_email: string | null
          updated_at: string
        }
        Insert: {
          country_code?: string | null
          created_at?: string
          employee_id: string
          mobile?: string | null
          personal_email?: string | null
          updated_at?: string
        }
        Update: {
          country_code?: string | null
          created_at?: string
          employee_id?: string
          mobile?: string | null
          personal_email?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_contact_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_contact_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      employee_employment: {
        Row: {
          created_at: string
          employee_id: string
          probation_end_date: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          employee_id: string
          probation_end_date?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          employee_id?: string
          probation_end_date?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_employment_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_employment_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      employee_invites: {
        Row: {
          attempt_no: number
          created_at: string
          employee_id: string
          error_message: string | null
          id: string
          reminder_sent_at: string | null
          sent_at: string
          status: string
          updated_at: string
        }
        Insert: {
          attempt_no?: number
          created_at?: string
          employee_id: string
          error_message?: string | null
          id?: string
          reminder_sent_at?: string | null
          sent_at?: string
          status?: string
          updated_at?: string
        }
        Update: {
          attempt_no?: number
          created_at?: string
          employee_id?: string
          error_message?: string | null
          id?: string
          reminder_sent_at?: string | null
          sent_at?: string
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_invites_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_invites_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      employee_personal: {
        Row: {
          created_at: string
          dob: string | null
          employee_id: string
          gender: string | null
          marital_status: string | null
          nationality: string | null
          photo_url: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          dob?: string | null
          employee_id: string
          gender?: string | null
          marital_status?: string | null
          nationality?: string | null
          photo_url?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          dob?: string | null
          employee_id?: string
          gender?: string | null
          marital_status?: string | null
          nationality?: string | null
          photo_url?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "employee_personal_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employee_personal_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      employees: {
        Row: {
          base_currency_id: string | null
          business_email: string | null
          created_at: string
          deleted_at: string | null
          dept_id: string | null
          designation: string | null
          employee_id: string
          end_date: string | null
          hire_date: string | null
          id: string
          invite_accepted_at: string | null
          invite_sent_at: string | null
          job_title: string | null
          manager_id: string | null
          name: string
          status: Database["public"]["Enums"]["employee_status"]
          updated_at: string
          work_country: string | null
          work_location: string | null
        }
        Insert: {
          base_currency_id?: string | null
          business_email?: string | null
          created_at?: string
          deleted_at?: string | null
          dept_id?: string | null
          designation?: string | null
          employee_id: string
          end_date?: string | null
          hire_date?: string | null
          id?: string
          invite_accepted_at?: string | null
          invite_sent_at?: string | null
          job_title?: string | null
          manager_id?: string | null
          name: string
          status?: Database["public"]["Enums"]["employee_status"]
          updated_at?: string
          work_country?: string | null
          work_location?: string | null
        }
        Update: {
          base_currency_id?: string | null
          business_email?: string | null
          created_at?: string
          deleted_at?: string | null
          dept_id?: string | null
          designation?: string | null
          employee_id?: string
          end_date?: string | null
          hire_date?: string | null
          id?: string
          invite_accepted_at?: string | null
          invite_sent_at?: string | null
          job_title?: string | null
          manager_id?: string | null
          name?: string
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
            foreignKeyName: "employees_base_currency_id_fkey"
            columns: ["base_currency_id"]
            isOneToOne: false
            referencedRelation: "vw_currencies_lookup"
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
            foreignKeyName: "employees_dept_id_fkey"
            columns: ["dept_id"]
            isOneToOne: false
            referencedRelation: "vw_departments_lookup"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_dept_id_fkey"
            columns: ["dept_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["department_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
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
            foreignKeyName: "exchange_rates_from_currency_id_fkey"
            columns: ["from_currency_id"]
            isOneToOne: false
            referencedRelation: "vw_currencies_lookup"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "exchange_rates_to_currency_id_fkey"
            columns: ["to_currency_id"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "exchange_rates_to_currency_id_fkey"
            columns: ["to_currency_id"]
            isOneToOne: false
            referencedRelation: "vw_currencies_lookup"
            referencedColumns: ["id"]
          },
        ]
      }
      expense_approvals: {
        Row: {
          action: string
          created_at: string
          id: string
          notes: string | null
          profile_id: string
          report_id: string
        }
        Insert: {
          action: string
          created_at?: string
          id?: string
          notes?: string | null
          profile_id: string
          report_id: string
        }
        Update: {
          action?: string
          created_at?: string
          id?: string
          notes?: string | null
          profile_id?: string
          report_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "expense_approvals_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_approvals_report_id_fkey"
            columns: ["report_id"]
            isOneToOne: false
            referencedRelation: "expense_reports"
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
            foreignKeyName: "expense_reports_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_reports_base_currency_id_fkey"
            columns: ["base_currency_id"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_reports_base_currency_id_fkey"
            columns: ["base_currency_id"]
            isOneToOne: false
            referencedRelation: "vw_currencies_lookup"
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
            foreignKeyName: "expense_reports_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "expense_reports_rejected_by_fkey"
            columns: ["rejected_by"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_reports_rejected_by_fkey"
            columns: ["rejected_by"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
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
          {
            foreignKeyName: "identity_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      job_run_log: {
        Row: {
          completed_at: string | null
          created_at: string
          duration_ms: number | null
          error_message: string | null
          id: string
          job_code: string
          job_name: string
          rows_processed: number | null
          started_at: string
          status: string
          summary: Json | null
          triggered_by: string | null
        }
        Insert: {
          completed_at?: string | null
          created_at?: string
          duration_ms?: number | null
          error_message?: string | null
          id?: string
          job_code: string
          job_name: string
          rows_processed?: number | null
          started_at?: string
          status?: string
          summary?: Json | null
          triggered_by?: string | null
        }
        Update: {
          completed_at?: string | null
          created_at?: string
          duration_ms?: number | null
          error_message?: string | null
          id?: string
          job_code?: string
          job_name?: string
          rows_processed?: number | null
          started_at?: string
          status?: string
          summary?: Json | null
          triggered_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "job_run_log_triggered_by_fkey"
            columns: ["triggered_by"]
            isOneToOne: false
            referencedRelation: "profiles"
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
            foreignKeyName: "line_items_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "vw_picklist_values_lookup"
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
            foreignKeyName: "line_items_currency_id_fkey"
            columns: ["currency_id"]
            isOneToOne: false
            referencedRelation: "vw_currencies_lookup"
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
            foreignKeyName: "line_items_project_id_fkey"
            columns: ["project_id"]
            isOneToOne: false
            referencedRelation: "vw_projects_lookup"
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
      module_codes: {
        Row: {
          code: string
          description: string | null
          label: string
        }
        Insert: {
          code: string
          description?: string | null
          label: string
        }
        Update: {
          code?: string
          description?: string | null
          label?: string
        }
        Relationships: []
      }
      module_registry: {
        Row: {
          approval_writable_statuses: string[] | null
          approval_write_permission: string | null
          code: string
          draft_status: string | null
          extra_view_permissions: string[] | null
          owner_column: string
          permission_prefix: string
          status_column: string
          table_name: string
          writable_statuses: string[] | null
          write_permission: string | null
        }
        Insert: {
          approval_writable_statuses?: string[] | null
          approval_write_permission?: string | null
          code: string
          draft_status?: string | null
          extra_view_permissions?: string[] | null
          owner_column: string
          permission_prefix: string
          status_column: string
          table_name: string
          writable_statuses?: string[] | null
          write_permission?: string | null
        }
        Update: {
          approval_writable_statuses?: string[] | null
          approval_write_permission?: string | null
          code?: string
          draft_status?: string | null
          extra_view_permissions?: string[] | null
          owner_column?: string
          permission_prefix?: string
          status_column?: string
          table_name?: string
          writable_statuses?: string[] | null
          write_permission?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "module_registry_code_fkey"
            columns: ["code"]
            isOneToOne: true
            referencedRelation: "module_codes"
            referencedColumns: ["code"]
          },
        ]
      }
      modules: {
        Row: {
          active: boolean | null
          code: string
          created_at: string | null
          id: string
          name: string
          sort_order: number | null
          updated_at: string | null
        }
        Insert: {
          active?: boolean | null
          code: string
          created_at?: string | null
          id?: string
          name: string
          sort_order?: number | null
          updated_at?: string | null
        }
        Update: {
          active?: boolean | null
          code?: string
          created_at?: string | null
          id?: string
          name?: string
          sort_order?: number | null
          updated_at?: string | null
        }
        Relationships: []
      }
      notification_attempts: {
        Row: {
          actor_id: string | null
          attempt_number: number
          attempted_at: string
          channel: string
          error_message: string | null
          id: string
          queue_id: string
          status: string
        }
        Insert: {
          actor_id?: string | null
          attempt_number: number
          attempted_at?: string
          channel?: string
          error_message?: string | null
          id?: string
          queue_id: string
          status: string
        }
        Update: {
          actor_id?: string | null
          attempt_number?: number
          attempted_at?: string
          channel?: string
          error_message?: string | null
          id?: string
          queue_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "notification_attempts_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notification_attempts_queue_id_fkey"
            columns: ["queue_id"]
            isOneToOne: false
            referencedRelation: "vw_notification_monitor"
            referencedColumns: ["queue_id"]
          },
          {
            foreignKeyName: "notification_attempts_queue_id_fkey"
            columns: ["queue_id"]
            isOneToOne: false
            referencedRelation: "workflow_notification_queue"
            referencedColumns: ["id"]
          },
        ]
      }
      notifications: {
        Row: {
          body: string | null
          created_at: string
          email_error: string | null
          email_sent_at: string | null
          email_status: string | null
          id: string
          is_read: boolean
          link: string | null
          profile_id: string
          title: string
        }
        Insert: {
          body?: string | null
          created_at?: string
          email_error?: string | null
          email_sent_at?: string | null
          email_status?: string | null
          id?: string
          is_read?: boolean
          link?: string | null
          profile_id: string
          title: string
        }
        Update: {
          body?: string | null
          created_at?: string
          email_error?: string | null
          email_sent_at?: string | null
          email_status?: string | null
          id?: string
          is_read?: boolean
          link?: string | null
          profile_id?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "notifications_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
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
          {
            foreignKeyName: "passports_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      permission_set_assignments: {
        Row: {
          created_at: string
          id: string
          permission_set_id: string
          role_id: string
          target_group_id: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          permission_set_id: string
          role_id: string
          target_group_id?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          permission_set_id?: string
          role_id?: string
          target_group_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "permission_set_assignments_permission_set_id_fkey"
            columns: ["permission_set_id"]
            isOneToOne: false
            referencedRelation: "permission_sets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "permission_set_assignments_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "permission_set_assignments_target_group_id_fkey"
            columns: ["target_group_id"]
            isOneToOne: false
            referencedRelation: "target_groups"
            referencedColumns: ["id"]
          },
        ]
      }
      permission_set_items: {
        Row: {
          permission_id: string
          permission_set_id: string
        }
        Insert: {
          permission_id: string
          permission_set_id: string
        }
        Update: {
          permission_id?: string
          permission_set_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "permission_set_items_permission_id_fkey"
            columns: ["permission_id"]
            isOneToOne: false
            referencedRelation: "permissions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "permission_set_items_permission_set_id_fkey"
            columns: ["permission_set_id"]
            isOneToOne: false
            referencedRelation: "permission_sets"
            referencedColumns: ["id"]
          },
        ]
      }
      permission_sets: {
        Row: {
          created_at: string
          created_by: string | null
          description: string | null
          id: string
          name: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          name: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          id?: string
          name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "permission_sets_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      permissions: {
        Row: {
          action: string | null
          code: string
          created_at: string | null
          description: string | null
          id: string
          module_id: string | null
          name: string
          sort_order: number
        }
        Insert: {
          action?: string | null
          code: string
          created_at?: string | null
          description?: string | null
          id?: string
          module_id?: string | null
          name: string
          sort_order?: number
        }
        Update: {
          action?: string | null
          code?: string
          created_at?: string | null
          description?: string | null
          id?: string
          module_id?: string | null
          name?: string
          sort_order?: number
        }
        Relationships: [
          {
            foreignKeyName: "permissions_module_id_fkey"
            columns: ["module_id"]
            isOneToOne: false
            referencedRelation: "modules"
            referencedColumns: ["id"]
          },
        ]
      }
      picklist_values: {
        Row: {
          active: boolean
          created_at: string
          id: string
          meta: Json | null
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
          meta?: Json | null
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
          meta?: Json | null
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
            foreignKeyName: "picklist_values_parent_value_id_fkey"
            columns: ["parent_value_id"]
            isOneToOne: false
            referencedRelation: "vw_picklist_values_lookup"
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
          meta_fields: Json
          name: string
          parent_picklist_id: string | null
          picklist_id: string
          system: boolean
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          meta_fields?: Json
          name: string
          parent_picklist_id?: string | null
          picklist_id: string
          system?: boolean
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          meta_fields?: Json
          name?: string
          parent_picklist_id?: string | null
          picklist_id?: string
          system?: boolean
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "picklists_parent_picklist_id_fkey"
            columns: ["parent_picklist_id"]
            isOneToOne: false
            referencedRelation: "picklists"
            referencedColumns: ["id"]
          },
        ]
      }
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
          {
            foreignKeyName: "profiles_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: true
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
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
      roles: {
        Row: {
          active: boolean
          code: string
          created_at: string | null
          description: string | null
          editable: boolean
          id: string
          is_system: boolean | null
          name: string
          role_type: string
          sort_order: number
          updated_at: string | null
        }
        Insert: {
          active?: boolean
          code: string
          created_at?: string | null
          description?: string | null
          editable?: boolean
          id?: string
          is_system?: boolean | null
          name: string
          role_type?: string
          sort_order?: number
          updated_at?: string | null
        }
        Update: {
          active?: boolean
          code?: string
          created_at?: string | null
          description?: string | null
          editable?: boolean
          id?: string
          is_system?: boolean | null
          name?: string
          role_type?: string
          sort_order?: number
          updated_at?: string | null
        }
        Relationships: []
      }
      super_admins: {
        Row: {
          granted_at: string
          granted_by: string | null
          profile_id: string
        }
        Insert: {
          granted_at?: string
          granted_by?: string | null
          profile_id: string
        }
        Update: {
          granted_at?: string
          granted_by?: string | null
          profile_id?: string
        }
        Relationships: []
      }
      target_group_members: {
        Row: {
          group_id: string
          member_id: string
        }
        Insert: {
          group_id: string
          member_id: string
        }
        Update: {
          group_id?: string
          member_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "target_group_members_group_id_fkey"
            columns: ["group_id"]
            isOneToOne: false
            referencedRelation: "target_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "target_group_members_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "target_group_members_member_id_fkey"
            columns: ["member_id"]
            isOneToOne: false
            referencedRelation: "pending_invite_reminders"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      target_groups: {
        Row: {
          code: string
          created_at: string
          filter_rules: Json | null
          id: string
          is_system: boolean
          label: string
          scope_type: string
        }
        Insert: {
          code: string
          created_at?: string
          filter_rules?: Json | null
          id?: string
          is_system?: boolean
          label: string
          scope_type: string
        }
        Update: {
          code?: string
          created_at?: string
          filter_rules?: Json | null
          id?: string
          is_system?: boolean
          label?: string
          scope_type?: string
        }
        Relationships: []
      }
      user_roles: {
        Row: {
          assignment_source: string
          expires_at: string | null
          granted_at: string | null
          granted_by: string | null
          id: string
          is_active: boolean
          profile_id: string | null
          role_id: string | null
          updated_at: string
        }
        Insert: {
          assignment_source?: string
          expires_at?: string | null
          granted_at?: string | null
          granted_by?: string | null
          id?: string
          is_active?: boolean
          profile_id?: string | null
          role_id?: string | null
          updated_at?: string
        }
        Update: {
          assignment_source?: string
          expires_at?: string | null
          granted_at?: string | null
          granted_by?: string | null
          id?: string
          is_active?: boolean
          profile_id?: string | null
          role_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_roles_granted_by_fkey"
            columns: ["granted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
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
          },
        ]
      }
      workflow_action_log: {
        Row: {
          action: string
          actor_id: string
          created_at: string
          id: string
          instance_id: string
          metadata: Json | null
          notes: string | null
          step_order: number | null
          task_id: string | null
        }
        Insert: {
          action: string
          actor_id: string
          created_at?: string
          id?: string
          instance_id: string
          metadata?: Json | null
          notes?: string | null
          step_order?: number | null
          task_id?: string | null
        }
        Update: {
          action?: string
          actor_id?: string
          created_at?: string
          id?: string
          instance_id?: string
          metadata?: Json | null
          notes?: string | null
          step_order?: number | null
          task_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "workflow_action_log_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_action_log_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_my_requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_action_log_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_action_log_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_pending_tasks"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_action_log_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "workflow_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_action_log_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["task_id"]
          },
          {
            foreignKeyName: "workflow_action_log_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_pending_tasks"
            referencedColumns: ["task_id"]
          },
          {
            foreignKeyName: "workflow_action_log_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "workflow_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_assignment_audit: {
        Row: {
          action: string
          assignment_id: string | null
          assignment_type: string
          changed_at: string
          changed_by: string | null
          entity_id: string | null
          id: string
          module_code: string
          new_effective_from: string | null
          new_effective_to: string | null
          new_template_id: string | null
          old_effective_from: string | null
          old_effective_to: string | null
          old_template_id: string | null
          reason: string | null
        }
        Insert: {
          action: string
          assignment_id?: string | null
          assignment_type: string
          changed_at?: string
          changed_by?: string | null
          entity_id?: string | null
          id?: string
          module_code: string
          new_effective_from?: string | null
          new_effective_to?: string | null
          new_template_id?: string | null
          old_effective_from?: string | null
          old_effective_to?: string | null
          old_template_id?: string | null
          reason?: string | null
        }
        Update: {
          action?: string
          assignment_id?: string | null
          assignment_type?: string
          changed_at?: string
          changed_by?: string | null
          entity_id?: string | null
          id?: string
          module_code?: string
          new_effective_from?: string | null
          new_effective_to?: string | null
          new_template_id?: string | null
          old_effective_from?: string | null
          old_effective_to?: string | null
          old_template_id?: string | null
          reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "workflow_assignment_audit_assignment_id_fkey"
            columns: ["assignment_id"]
            isOneToOne: false
            referencedRelation: "workflow_assignments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_assignment_audit_changed_by_fkey"
            columns: ["changed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_assignment_audit_new_template_id_fkey"
            columns: ["new_template_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["template_id"]
          },
          {
            foreignKeyName: "workflow_assignment_audit_new_template_id_fkey"
            columns: ["new_template_id"]
            isOneToOne: false
            referencedRelation: "workflow_templates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_assignment_audit_old_template_id_fkey"
            columns: ["old_template_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["template_id"]
          },
          {
            foreignKeyName: "workflow_assignment_audit_old_template_id_fkey"
            columns: ["old_template_id"]
            isOneToOne: false
            referencedRelation: "workflow_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_assignments: {
        Row: {
          assignment_type: string
          created_at: string
          created_by: string | null
          effective_from: string
          effective_to: string | null
          entity_id: string | null
          entity_id_coalesced: string | null
          id: string
          is_active: boolean
          module_code: string
          priority: number
          updated_at: string
          wf_template_id: string
        }
        Insert: {
          assignment_type: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          effective_to?: string | null
          entity_id?: string | null
          entity_id_coalesced?: string | null
          id?: string
          is_active?: boolean
          module_code: string
          priority?: number
          updated_at?: string
          wf_template_id: string
        }
        Update: {
          assignment_type?: string
          created_at?: string
          created_by?: string | null
          effective_from?: string
          effective_to?: string | null
          entity_id?: string | null
          entity_id_coalesced?: string | null
          id?: string
          is_active?: boolean
          module_code?: string
          priority?: number
          updated_at?: string
          wf_template_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "workflow_assignments_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_assignments_wf_template_id_fkey"
            columns: ["wf_template_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["template_id"]
          },
          {
            foreignKeyName: "workflow_assignments_wf_template_id_fkey"
            columns: ["wf_template_id"]
            isOneToOne: false
            referencedRelation: "workflow_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_authorities: {
        Row: {
          can_approve: boolean | null
          can_reassign: boolean | null
          can_reject: boolean | null
          created_at: string | null
          id: string
          profile_id: string | null
          stage_code: string
          updated_at: string | null
          workflow_code: string
        }
        Insert: {
          can_approve?: boolean | null
          can_reassign?: boolean | null
          can_reject?: boolean | null
          created_at?: string | null
          id?: string
          profile_id?: string | null
          stage_code: string
          updated_at?: string | null
          workflow_code: string
        }
        Update: {
          can_approve?: boolean | null
          can_reassign?: boolean | null
          can_reject?: boolean | null
          created_at?: string | null
          id?: string
          profile_id?: string | null
          stage_code?: string
          updated_at?: string | null
          workflow_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "workflow_authorities_profile_id_fkey"
            columns: ["profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_delegations: {
        Row: {
          created_at: string
          created_by: string | null
          delegate_id: string
          delegator_id: string
          from_date: string
          id: string
          is_active: boolean
          reason: string | null
          template_id: string | null
          to_date: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          delegate_id: string
          delegator_id: string
          from_date: string
          id?: string
          is_active?: boolean
          reason?: string | null
          template_id?: string | null
          to_date: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          delegate_id?: string
          delegator_id?: string
          from_date?: string
          id?: string
          is_active?: boolean
          reason?: string | null
          template_id?: string | null
          to_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "workflow_delegations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_delegations_delegate_id_fkey"
            columns: ["delegate_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_delegations_delegator_id_fkey"
            columns: ["delegator_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_delegations_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["template_id"]
          },
          {
            foreignKeyName: "workflow_delegations_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "workflow_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_instances: {
        Row: {
          completed_at: string | null
          created_at: string
          current_step: number
          id: string
          metadata: Json
          module_code: string
          record_id: string
          status: string
          submitted_by: string
          template_id: string
          template_version: number
          updated_at: string
        }
        Insert: {
          completed_at?: string | null
          created_at?: string
          current_step?: number
          id?: string
          metadata?: Json
          module_code: string
          record_id: string
          status?: string
          submitted_by: string
          template_id: string
          template_version?: number
          updated_at?: string
        }
        Update: {
          completed_at?: string | null
          created_at?: string
          current_step?: number
          id?: string
          metadata?: Json
          module_code?: string
          record_id?: string
          status?: string
          submitted_by?: string
          template_id?: string
          template_version?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_wi_module_code"
            columns: ["module_code"]
            isOneToOne: false
            referencedRelation: "module_codes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "workflow_instances_submitted_by_fkey"
            columns: ["submitted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_instances_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["template_id"]
          },
          {
            foreignKeyName: "workflow_instances_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "workflow_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_notification_queue: {
        Row: {
          created_at: string
          error_message: string | null
          id: string
          instance_id: string
          max_retries: number
          notification_id: string | null
          payload: Json
          processed_at: string | null
          retry_count: number
          status: string
          target_profile: string
          template_code: string
        }
        Insert: {
          created_at?: string
          error_message?: string | null
          id?: string
          instance_id: string
          max_retries?: number
          notification_id?: string | null
          payload?: Json
          processed_at?: string | null
          retry_count?: number
          status?: string
          target_profile: string
          template_code: string
        }
        Update: {
          created_at?: string
          error_message?: string | null
          id?: string
          instance_id?: string
          max_retries?: number
          notification_id?: string | null
          payload?: Json
          processed_at?: string | null
          retry_count?: number
          status?: string
          target_profile?: string
          template_code?: string
        }
        Relationships: [
          {
            foreignKeyName: "workflow_notification_queue_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_my_requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_pending_tasks"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "workflow_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_notification_id_fkey"
            columns: ["notification_id"]
            isOneToOne: false
            referencedRelation: "notifications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_target_profile_fkey"
            columns: ["target_profile"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_notification_templates: {
        Row: {
          body_tmpl: string
          code: string
          created_at: string
          id: string
          title_tmpl: string
          updated_at: string
        }
        Insert: {
          body_tmpl: string
          code: string
          created_at?: string
          id?: string
          title_tmpl: string
          updated_at?: string
        }
        Update: {
          body_tmpl?: string
          code?: string
          created_at?: string
          id?: string
          title_tmpl?: string
          updated_at?: string
        }
        Relationships: []
      }
      workflow_pending_changes: {
        Row: {
          action: string
          created_at: string
          current_data: Json | null
          id: string
          instance_id: string | null
          module_code: string
          proposed_data: Json
          record_id: string | null
          resolved_at: string | null
          status: string
          submitted_by: string | null
          updated_at: string | null
        }
        Insert: {
          action?: string
          created_at?: string
          current_data?: Json | null
          id?: string
          instance_id?: string | null
          module_code: string
          proposed_data?: Json
          record_id?: string | null
          resolved_at?: string | null
          status?: string
          submitted_by?: string | null
          updated_at?: string | null
        }
        Update: {
          action?: string
          created_at?: string
          current_data?: Json | null
          id?: string
          instance_id?: string | null
          module_code?: string
          proposed_data?: Json
          record_id?: string | null
          resolved_at?: string | null
          status?: string
          submitted_by?: string | null
          updated_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "workflow_pending_changes_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_my_requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_pending_changes_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_pending_changes_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_pending_tasks"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_pending_changes_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "workflow_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_pending_changes_submitted_by_fkey"
            columns: ["submitted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_sla_events: {
        Row: {
          event_type: string
          fired_at: string
          id: string
          task_id: string
        }
        Insert: {
          event_type: string
          fired_at?: string
          id?: string
          task_id: string
        }
        Update: {
          event_type?: string
          fired_at?: string
          id?: string
          task_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "workflow_sla_events_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["task_id"]
          },
          {
            foreignKeyName: "workflow_sla_events_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_pending_tasks"
            referencedColumns: ["task_id"]
          },
          {
            foreignKeyName: "workflow_sla_events_task_id_fkey"
            columns: ["task_id"]
            isOneToOne: false
            referencedRelation: "workflow_tasks"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_step_conditions: {
        Row: {
          created_at: string
          field_path: string
          id: string
          operator: string
          skip_step: boolean
          step_id: string
          value: string
        }
        Insert: {
          created_at?: string
          field_path: string
          id?: string
          operator: string
          skip_step?: boolean
          step_id: string
          value: string
        }
        Update: {
          created_at?: string
          field_path?: string
          id?: string
          operator?: string
          skip_step?: boolean
          step_id?: string
          value?: string
        }
        Relationships: [
          {
            foreignKeyName: "workflow_step_conditions_step_id_fkey"
            columns: ["step_id"]
            isOneToOne: false
            referencedRelation: "workflow_steps"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_steps: {
        Row: {
          allow_delegation: boolean
          allow_edit: boolean
          approver_profile_id: string | null
          approver_role: string | null
          approver_type: string
          created_at: string
          escalation_after_hours: number | null
          id: string
          is_active: boolean
          is_cc: boolean
          is_mandatory: boolean
          name: string
          notification_template_id: string | null
          reminder_after_hours: number | null
          sla_hours: number | null
          step_order: number
          template_id: string
        }
        Insert: {
          allow_delegation?: boolean
          allow_edit?: boolean
          approver_profile_id?: string | null
          approver_role?: string | null
          approver_type: string
          created_at?: string
          escalation_after_hours?: number | null
          id?: string
          is_active?: boolean
          is_cc?: boolean
          is_mandatory?: boolean
          name: string
          notification_template_id?: string | null
          reminder_after_hours?: number | null
          sla_hours?: number | null
          step_order: number
          template_id: string
        }
        Update: {
          allow_delegation?: boolean
          allow_edit?: boolean
          approver_profile_id?: string | null
          approver_role?: string | null
          approver_type?: string
          created_at?: string
          escalation_after_hours?: number | null
          id?: string
          is_active?: boolean
          is_cc?: boolean
          is_mandatory?: boolean
          name?: string
          notification_template_id?: string | null
          reminder_after_hours?: number | null
          sla_hours?: number | null
          step_order?: number
          template_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "workflow_steps_approver_profile_id_fkey"
            columns: ["approver_profile_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_steps_notification_template_id_fkey"
            columns: ["notification_template_id"]
            isOneToOne: false
            referencedRelation: "workflow_notification_templates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_steps_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["template_id"]
          },
          {
            foreignKeyName: "workflow_steps_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "workflow_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_tasks: {
        Row: {
          acted_at: string | null
          assigned_to: string
          created_at: string
          due_at: string | null
          escalated_at: string | null
          id: string
          instance_id: string
          notes: string | null
          status: string
          step_id: string
          step_order: number
        }
        Insert: {
          acted_at?: string | null
          assigned_to: string
          created_at?: string
          due_at?: string | null
          escalated_at?: string | null
          id?: string
          instance_id: string
          notes?: string | null
          status?: string
          step_id: string
          step_order: number
        }
        Update: {
          acted_at?: string | null
          assigned_to?: string
          created_at?: string
          due_at?: string | null
          escalated_at?: string | null
          id?: string
          instance_id?: string
          notes?: string | null
          status?: string
          step_id?: string
          step_order?: number
        }
        Relationships: [
          {
            foreignKeyName: "workflow_tasks_assigned_to_fkey"
            columns: ["assigned_to"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_tasks_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_my_requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_tasks_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_tasks_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_pending_tasks"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_tasks_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "workflow_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_tasks_step_id_fkey"
            columns: ["step_id"]
            isOneToOne: false
            referencedRelation: "workflow_steps"
            referencedColumns: ["id"]
          },
        ]
      }
      workflow_templates: {
        Row: {
          code: string
          created_at: string
          description: string | null
          effective_from: string | null
          id: string
          is_active: boolean
          module_code: string | null
          name: string
          parent_version: number | null
          published_at: string | null
          remove_duplicate_approver: boolean
          skip_duplicate_approver: boolean
          updated_at: string
          version: number
        }
        Insert: {
          code: string
          created_at?: string
          description?: string | null
          effective_from?: string | null
          id?: string
          is_active?: boolean
          module_code?: string | null
          name: string
          parent_version?: number | null
          published_at?: string | null
          remove_duplicate_approver?: boolean
          skip_duplicate_approver?: boolean
          updated_at?: string
          version?: number
        }
        Update: {
          code?: string
          created_at?: string
          description?: string | null
          effective_from?: string | null
          id?: string
          is_active?: boolean
          module_code?: string | null
          name?: string
          parent_version?: number | null
          published_at?: string | null
          remove_duplicate_approver?: boolean
          skip_duplicate_approver?: boolean
          updated_at?: string
          version?: number
        }
        Relationships: []
      }
    }
    Views: {
      pending_invite_reminders: {
        Row: {
          attempt_no: number | null
          business_email: string | null
          employee_id: string | null
          employee_name: string | null
          invite_id: string | null
          reminder_sent_at: string | null
          sent_at: string | null
        }
        Relationships: []
      }
      vw_currencies_lookup: {
        Row: {
          code: string | null
          id: string | null
          name: string | null
          symbol: string | null
        }
        Insert: {
          code?: string | null
          id?: string | null
          name?: string | null
          symbol?: string | null
        }
        Update: {
          code?: string | null
          id?: string | null
          name?: string | null
          symbol?: string | null
        }
        Relationships: []
      }
      vw_departments_lookup: {
        Row: {
          dept_id: string | null
          id: string | null
          name: string | null
        }
        Insert: {
          dept_id?: string | null
          id?: string | null
          name?: string | null
        }
        Update: {
          dept_id?: string | null
          id?: string | null
          name?: string | null
        }
        Relationships: []
      }
      vw_notification_monitor: {
        Row: {
          can_retry: boolean | null
          created_at: string | null
          display_id: string | null
          email_error: string | null
          email_sent_at: string | null
          email_status: string | null
          inapp_error: string | null
          inapp_status: string | null
          instance_id: string | null
          max_retries: number | null
          module_code: string | null
          notification_id: string | null
          overall_status: string | null
          payload: Json | null
          processed_at: string | null
          queue_id: string | null
          recipient_dept: string | null
          recipient_email: string | null
          recipient_id: string | null
          recipient_name: string | null
          record_id: string | null
          retry_count: number | null
          template_code: string | null
          template_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_wi_module_code"
            columns: ["module_code"]
            isOneToOne: false
            referencedRelation: "module_codes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "workflow_notification_queue_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_my_requests"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_operations"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "vw_wf_pending_tasks"
            referencedColumns: ["instance_id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_instance_id_fkey"
            columns: ["instance_id"]
            isOneToOne: false
            referencedRelation: "workflow_instances"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_notification_id_fkey"
            columns: ["notification_id"]
            isOneToOne: false
            referencedRelation: "notifications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_notification_queue_target_profile_fkey"
            columns: ["recipient_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      vw_picklist_values_lookup: {
        Row: {
          id: string | null
          parent_value_id: string | null
          picklist_code: string | null
          ref_id: string | null
          value: string | null
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
            foreignKeyName: "picklist_values_parent_value_id_fkey"
            columns: ["parent_value_id"]
            isOneToOne: false
            referencedRelation: "vw_picklist_values_lookup"
            referencedColumns: ["id"]
          },
        ]
      }
      vw_projects_lookup: {
        Row: {
          end_date: string | null
          id: string | null
          name: string | null
          start_date: string | null
        }
        Insert: {
          end_date?: string | null
          id?: string | null
          name?: string | null
          start_date?: string | null
        }
        Update: {
          end_date?: string | null
          id?: string | null
          name?: string | null
          start_date?: string | null
        }
        Relationships: []
      }
      vw_wf_my_requests: {
        Row: {
          clarification_at: string | null
          clarification_from: string | null
          clarification_message: string | null
          completed_at: string | null
          current_approver_id: string | null
          current_approver_name: string | null
          current_step: number | null
          current_task_due: string | null
          id: string | null
          metadata: Json | null
          module_code: string | null
          record_id: string | null
          status: string | null
          submitted_at: string | null
          template_code: string | null
          template_name: string | null
          updated_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_wi_module_code"
            columns: ["module_code"]
            isOneToOne: false
            referencedRelation: "module_codes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "workflow_tasks_assigned_to_fkey"
            columns: ["current_approver_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      vw_wf_operations: {
        Row: {
          age_days: number | null
          age_hours: number | null
          assignee_id: string | null
          assignee_job_title: string | null
          assignee_name: string | null
          department_id: string | null
          department_name: string | null
          display_id: string | null
          due_at: string | null
          instance_id: string | null
          instance_status: string | null
          module_code: string | null
          pending_since: string | null
          record_id: string | null
          sla_hours: number | null
          sla_status: string | null
          step_name: string | null
          step_order: number | null
          submitted_at: string | null
          submitter_id: string | null
          submitter_name: string | null
          task_id: string | null
          template_code: string | null
          template_id: string | null
          template_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_wi_module_code"
            columns: ["module_code"]
            isOneToOne: false
            referencedRelation: "module_codes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "workflow_instances_submitted_by_fkey"
            columns: ["submitter_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_tasks_assigned_to_fkey"
            columns: ["assignee_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      vw_wf_pending_tasks: {
        Row: {
          assigned_to: string | null
          current_data: Json | null
          due_at: string | null
          instance_id: string | null
          metadata: Json | null
          module_code: string | null
          record_id: string | null
          sla_status: string | null
          step_name: string | null
          step_order: number | null
          submitted_by: string | null
          submitted_by_email: string | null
          submitted_by_name: string | null
          task_created_at: string | null
          task_id: string | null
          template_code: string | null
          template_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_wi_module_code"
            columns: ["module_code"]
            isOneToOne: false
            referencedRelation: "module_codes"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "workflow_instances_submitted_by_fkey"
            columns: ["submitted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workflow_tasks_assigned_to_fkey"
            columns: ["assigned_to"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      _wf_instance_visible: {
        Args: { p_instance_id: string }
        Returns: boolean
      }
      backfill_ess_for_active_employees: { Args: never; Returns: Json }
      can_view_module_record: {
        Args: { p_module: string; p_record_id: string }
        Returns: boolean
      }
      can_write_module_record: {
        Args: { p_module: string; p_record_id: string }
        Returns: boolean
      }
      deactivate_workflow_assignment: { Args: { p_id: string }; Returns: Json }
      delete_expense_report: {
        Args: { p_report_id: string }
        Returns: undefined
      }
      delete_picklist_values: { Args: { p_ids: string[] }; Returns: undefined }
      explain_user_can: {
        Args: {
          p_action: string
          p_module: string
          p_owner: string
          p_uid: string
        }
        Returns: {
          matching_group: string
          matching_role: string
          path_taken: string
          reason: string
          result: boolean
        }[]
      }
      get_active_transaction_count: {
        Args: { p_module_code: string }
        Returns: number
      }
      get_approver_performance: {
        Args: { p_from: string; p_template_code?: string; p_to: string }
        Returns: {
          approval_rate: number
          approved_count: number
          approver_id: string
          approver_name: string
          avg_hours: number
          department_name: string
          job_title: string
          median_hours: number
          overdue_count: number
          pending_count: number
          reassigned_count: number
          rejected_count: number
          returned_count: number
          total_actioned: number
        }[]
      }
      get_attachment_url: { Args: { p_attachment_id: string }; Returns: string }
      get_my_employee_id: { Args: never; Returns: string }
      get_my_permissions: { Args: never; Returns: string[] }
      get_my_workflow_action_log: {
        Args: { p_instance_id: string }
        Returns: {
          action: string
          actor_id: string
          actor_name: string
          created_at: string
          id: string
          notes: string
          step_order: number
        }[]
      }
      get_my_workflow_instance: {
        Args: { p_module_code: string; p_record_id: string }
        Returns: {
          completed_at: string
          created_at: string
          current_step: number
          id: string
          metadata: Json
          module_code: string
          record_id: string
          status: string
          submitted_by: string
          template_code: string
          template_id: string
          template_name: string
          updated_at: string
        }[]
      }
      get_my_workflow_tasks: {
        Args: { p_instance_id: string }
        Returns: {
          acted_at: string
          assigned_to: string
          assignee_name: string
          created_at: string
          due_at: string
          id: string
          notes: string
          status: string
          step_id: string
          step_name: string
          step_order: number
        }[]
      }
      get_pending_count: {
        Args: { p_module_code: string; p_submitted_by?: string }
        Returns: number
      }
      get_profile_workflow_gates: { Args: never; Returns: Json }
      get_record_history: {
        Args: { p_entity_id: string; p_entity_type: string }
        Returns: {
          action: string
          actor_name: string
          changed_at: string
          changed_by: string
          id: string
          metadata: Json
        }[]
      }
      get_step_bottlenecks: {
        Args: { p_from?: string; p_template_code?: string; p_to?: string }
        Returns: {
          avg_duration_hours: number
          overdue_count: number
          rejection_rate_pct: number
          sla_hours: number
          step_name: string
          step_order: number
          template_code: string
          template_name: string
          total_tasks: number
        }[]
      }
      get_target_employee_ids: {
        Args: { p_action?: string; p_module?: string }
        Returns: string[]
      }
      get_target_population: {
        Args: { p_action: string; p_module: string }
        Returns: Json
      }
      get_user_permissions: {
        Args: { p_profile_id: string }
        Returns: {
          module_code: string
          module_name: string
          module_sort: number
          permission_code: string
          permission_desc: string
          permission_name: string
          role_codes: string
          role_names: string
          user_designation: string
          user_email: string
          user_employee_id: string
          user_name: string
          user_status: string
          via_roles: string
        }[]
      }
      get_user_roles: {
        Args: { p_profile_id: string }
        Returns: {
          assignment_source: string
          granted_at: string
          role_code: string
          role_name: string
        }[]
      }
      get_users_by_permission: {
        Args: { p_permission_code: string }
        Returns: {
          designation: string
          email: string
          employee_id: string
          granted_at: string
          name: string
          profile_id: string
          status: string
          via_role_code: string
          via_role_name: string
        }[]
      }
      get_workflow_participants: {
        Args: { p_module_code: string; p_profile_id?: string }
        Returns: Json
      }
      get_workflow_summary: {
        Args: { p_from?: string; p_template_code?: string; p_to?: string }
        Returns: {
          avg_completion_hours: number
          template_code: string
          template_name: string
          total_approved: number
          total_in_progress: number
          total_rejected: number
          total_submitted: number
        }[]
      }
      has_any_role: { Args: { check_roles: string[] }; Returns: boolean }
      has_permission: { Args: { check_permission: string }; Returns: boolean }
      has_role: { Args: { check_role: string }; Returns: boolean }
      insert_picklist_value: {
        Args: {
          p_meta?: Json
          p_parent_value_id?: string
          p_picklist_id: string
          p_ref_id?: string
          p_value: string
        }
        Returns: string
      }
      is_in_my_department: { Args: { emp_id: string }; Returns: boolean }
      is_in_my_org_subtree: { Args: { emp_id: string }; Returns: boolean }
      is_my_direct_report: { Args: { emp_id: string }; Returns: boolean }
      is_super_admin: { Args: never; Returns: boolean }
      is_wf_task_assignee: { Args: { p_instance_id: string }; Returns: boolean }
      is_workflow_assignee: {
        Args: { p_module_code: string; p_record_id: string }
        Returns: boolean
      }
      is_workflow_awaiting_clarification: {
        Args: { p_module_code: string; p_record_id: string }
        Returns: boolean
      }
      link_profile_to_employee: { Args: { p_email: string }; Returns: Json }
      notify_delegation_created: {
        Args: { p_delegation_id: string }
        Returns: undefined
      }
      recall_expense:
        | { Args: { p_report_id: string }; Returns: undefined }
        | {
            Args: { p_reason?: string; p_report_id: string }
            Returns: undefined
          }
      reconcile_employee_profiles: { Args: never; Returns: Json }
      resolve_workflow_for_submission: {
        Args: { p_module_code: string; p_profile_id: string }
        Returns: string
      }
      rpc_expense_kpis: {
        Args: {
          p_date_from?: string
          p_date_to?: string
          p_dept_id?: string
          p_employee_id?: string
        }
        Returns: Json
      }
      rpc_expense_status_funnel: {
        Args: {
          p_date_from?: string
          p_date_to?: string
          p_dept_id?: string
          p_employee_id?: string
        }
        Returns: {
          count: number
          status: string
        }[]
      }
      rpc_monthly_spend_trend: {
        Args: { p_dept_id?: string; p_employee_id?: string; p_months?: number }
        Returns: {
          count: number
          month: string
          month_start: string
          spend: number
        }[]
      }
      rpc_pending_approvals: {
        Args: { p_dept_id?: string; p_employee_id?: string }
        Returns: {
          assignee_name: string
          currency_code: string
          current_step: string
          days_waiting: number
          dept_name: string
          employee_name: string
          report_id: string
          report_name: string
          status: string
          submitted_at: string
          total_amount: number
        }[]
      }
      rpc_spend_by_department: {
        Args: {
          p_date_from?: string
          p_date_to?: string
          p_dept_id?: string
          p_employee_id?: string
        }
        Returns: {
          count: number
          dept_id: string
          dept_name: string
          spend: number
        }[]
      }
      save_workflow_assignment: {
        Args: {
          p_assignment_type: string
          p_effective_from: string
          p_effective_to: string
          p_entity_id: string
          p_id: string
          p_module_code: string
          p_priority: number
          p_reason?: string
          p_wf_template_id: string
        }
        Returns: Json
      }
      search_users_for_rbp: {
        Args: { p_query: string }
        Returns: {
          designation: string
          email: string
          employee_id: string
          name: string
          profile_id: string
          role_codes: string
          status: string
        }[]
      }
      submit_change_request:
        | {
            Args: {
              p_action?: string
              p_module_code: string
              p_proposed_data?: Json
              p_record_id?: string
            }
            Returns: Json
          }
        | {
            Args: {
              p_action?: string
              p_comment?: string
              p_module_code: string
              p_proposed_data?: Json
              p_record_id?: string
            }
            Returns: Json
          }
      submit_expense: { Args: { p_report_id: string }; Returns: undefined }
      sync_employee_ess: { Args: never; Returns: Json }
      sync_single_target_group: {
        Args: { p_group_id: string }
        Returns: undefined
      }
      sync_system_roles: { Args: { p_role_code?: string }; Returns: Json }
      sync_target_group_members: { Args: never; Returns: undefined }
      user_can: {
        Args: { p_action: string; p_module: string; p_owner: string }
        Returns: boolean
      }
      wf_add_step:
        | {
            Args: {
              p_allow_delegation?: boolean
              p_approver_profile_id?: string
              p_approver_role?: string
              p_approver_type: string
              p_escalation_hours?: number
              p_is_mandatory?: boolean
              p_name: string
              p_reminder_hours?: number
              p_sla_hours?: number
              p_step_order: number
              p_template_id: string
            }
            Returns: string
          }
        | {
            Args: {
              p_allow_delegation?: boolean
              p_approver_profile_id?: string
              p_approver_role?: string
              p_approver_type: string
              p_escalation_hours?: number
              p_is_cc?: boolean
              p_is_mandatory?: boolean
              p_name: string
              p_notification_template_id?: string
              p_reminder_hours?: number
              p_sla_hours?: number
              p_step_order: number
              p_template_id: string
            }
            Returns: string
          }
      wf_admin_decline: {
        Args: { p_instance_id: string; p_reason: string }
        Returns: undefined
      }
      wf_advance_instance: {
        Args: { p_instance_id: string }
        Returns: undefined
      }
      wf_analytics_rejection_rates: {
        Args: { p_from?: string; p_to?: string }
        Returns: {
          approved_count: number
          completed_late: number
          overdue_now: number
          rejected_count: number
          rejection_pct: number
          sla_breach_pct: number
          sla_hours: number
          step_name: string
          step_order: number
          template_code: string
          template_name: string
          total_tasks: number
        }[]
      }
      wf_analytics_submitter_activity: {
        Args: { p_from?: string; p_to?: string }
        Returns: {
          approved_count: number
          avg_turnaround_hours: number
          department_name: string
          employee_id: string
          employee_name: string
          in_progress_count: number
          rejected_count: number
          total_submissions: number
        }[]
      }
      wf_analytics_turnaround: {
        Args: { p_from?: string; p_to?: string }
        Returns: {
          approved_count: number
          avg_hours_all: number
          avg_hours_approved: number
          avg_hours_rejected: number
          in_progress_count: number
          max_hours: number
          min_hours: number
          rejected_count: number
          template_code: string
          template_id: string
          template_name: string
          total_submitted: number
        }[]
      }
      wf_approve: {
        Args: { p_notes?: string; p_task_id: string }
        Returns: undefined
      }
      wf_bulk_approve: {
        Args: { p_notes?: string; p_task_ids: string[] }
        Returns: Json
      }
      wf_bulk_decline: {
        Args: { p_reason: string; p_task_ids: string[] }
        Returns: Json
      }
      wf_bulk_reassign: {
        Args: {
          p_new_profile_id: string
          p_reason?: string
          p_task_ids: string[]
        }
        Returns: Json
      }
      wf_clone_template: { Args: { p_template_id: string }; Returns: string }
      wf_delete_step: { Args: { p_step_id: string }; Returns: undefined }
      wf_deliver_pending_notifications: { Args: never; Returns: number }
      wf_escalate_overdue_tasks: { Args: never; Returns: number }
      wf_evaluate_skip_step: {
        Args: { p_metadata: Json; p_step_id: string }
        Returns: boolean
      }
      wf_find_active_template: { Args: { p_code: string }; Returns: string }
      wf_force_advance: {
        Args: {
          p_instance_id: string
          p_reason: string
          p_target_step_order: number
        }
        Returns: undefined
      }
      wf_prepare_update: {
        Args: { p_instance_id: string }
        Returns: {
          module_code: string
          record_id: string
        }[]
      }
      wf_process_sla_events: {
        Args: { p_triggered_by?: string }
        Returns: Json
      }
      wf_publish_template: {
        Args: { p_template_id: string }
        Returns: undefined
      }
      wf_queue_notification: {
        Args: {
          p_instance_id: string
          p_payload?: Json
          p_target_profile: string
          p_template_code: string
        }
        Returns: undefined
      }
      wf_reassign: {
        Args: { p_new_profile_id: string; p_reason?: string; p_task_id: string }
        Returns: undefined
      }
      wf_reject: {
        Args: { p_reason: string; p_task_id: string }
        Returns: undefined
      }
      wf_resolve_approver: {
        Args: { p_instance_id: string; p_step_id: string }
        Returns: string
      }
      wf_resubmit:
        | {
            Args: { p_instance_id: string; p_response?: string }
            Returns: undefined
          }
        | {
            Args: {
              p_instance_id: string
              p_proposed_data?: Json
              p_response?: string
            }
            Returns: undefined
          }
      wf_retry_failed_emails:
        | { Args: { p_max_age_hours?: number }; Returns: number }
        | {
            Args: { p_max_age_hours?: number; p_triggered_by?: string }
            Returns: number
          }
      wf_retry_notification: {
        Args: { p_force?: boolean; p_queue_id: string }
        Returns: undefined
      }
      wf_return_to_initiator: {
        Args: { p_message: string; p_task_id: string }
        Returns: undefined
      }
      wf_return_to_previous_step: {
        Args: { p_reason?: string; p_task_id: string }
        Returns: undefined
      }
      wf_submit: {
        Args: {
          p_comment?: string
          p_metadata?: Json
          p_module_code: string
          p_record_id: string
          p_template_code: string
        }
        Returns: string
      }
      wf_sync_module_status: {
        Args: { p_module_code: string; p_record_id: string; p_status: string }
        Returns: undefined
      }
      wf_withdraw: {
        Args: { p_instance_id: string; p_reason?: string }
        Returns: undefined
      }
      wf_withdraw_by_record: {
        Args: { p_module_code: string; p_reason?: string; p_record_id: string }
        Returns: undefined
      }
    }
    Enums: {
      employee_status: "Draft" | "Incomplete" | "Active" | "Inactive"
      expense_status:
        | "draft"
        | "submitted"
        | "needs_update"
        | "manager_approved"
        | "approved"
        | "rejected"
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
      expense_status: [
        "draft",
        "submitted",
        "needs_update",
        "manager_approved",
        "approved",
        "rejected",
      ],
    },
  },
} as const

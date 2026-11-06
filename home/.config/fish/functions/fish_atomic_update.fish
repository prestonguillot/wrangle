function fish_atomic_update --description "Atomically update Fish configuration files with backup and logging"
    set -l script_path "$HOME/.config/fish_atomic_writer.py"
    
    if not test -x "$script_path"
        echo "Error: Atomic writer script not found or not executable: $script_path"
        return 1
    end
    
    # Check if Python 3 is available
    if not command -q python3
        echo "Error: Python 3 is required but not found"
        return 1
    end
    
    # Parse arguments
    if test (count $argv) -eq 0; or test "$argv[1]" = "--help"; or test "$argv[1]" = "-h"
        echo "Usage: fish_atomic_update [OPTIONS] [source_file] [target_file]"
        echo ""
        echo "Atomically update Fish configuration files with automatic backup and logging."
        echo ""
        echo "Options:"
        echo "  --backup-only        Only create backup, do not copy files"
        echo "  --log-file PATH      Custom log file path"
        echo "  --help, -h           Show this help message"
        echo ""
        echo "Examples:"
        echo "  fish_atomic_update --backup-only"
        echo "  fish_atomic_update new_config.fish ~/.config/fish/config.fish"
        echo "  fish_atomic_update --log-file /tmp/update.log new.fish ~/.config/fish/config.fish"
        return 0
    end
    
    # Execute the Python script with all arguments
    python3 "$script_path" $argv
    set -l exit_code $status
    
    if test $exit_code -eq 0
        echo ""
        echo "✅ Operation completed successfully!"
        echo "📄 Check log file: $HOME/.config/fish_update.log"
        
        if test (count $argv) -gt 1; and not string match -q "*--backup-only*" "$argv"
            echo "💡 You may want to restart your Fish session or run 'source ~/.config/fish/config.fish'"
        end
    else
        echo ""
        echo "❌ Operation failed!"
        echo "📄 Check log file for details: $HOME/.config/fish_update.log"
    end
    
    return $exit_code
end

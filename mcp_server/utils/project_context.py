from pathlib import Path

def find_project_root(start: Path) -> Path:
    """
    Walk up from start until we find .git or .tickets/, or return start.
    
    Args:
        start: The directory to start searching from.
        
    Returns:
        The path to the project root.
    """
    d = start.resolve()
    while d != d.parent:
        if (d / '.git').exists():
            return d
        if (d / '.tickets').exists():
            return d
        d = d.parent
    return start.resolve()

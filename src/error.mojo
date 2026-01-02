"""
JSON Parse Error Types

Provides structured error information for JSON parsing failures.
Includes position tracking for helpful error messages.

Example:
    var err = JsonParseError(
        message="Unexpected character",
        position=42,
        line=3,
        column=15
    )
    print(err.format())  # "JSON parse error at line 3, column 15: Unexpected character"
"""


struct JsonParseError(Copyable, Movable, Stringable):
    """
    Represents a JSON parsing error with position information.

    Attributes:
        message: Description of the error.
        position: Byte offset in the source string.
        line: Line number (1-indexed).
        column: Column number (1-indexed).
    """

    var message: String
    """Description of the error."""

    var position: Int
    """Byte offset in the source string."""

    var line: Int
    """Line number (1-indexed)."""

    var column: Int
    """Column number (1-indexed)."""

    fn __init__(out self, message: String):
        """Create error with just a message."""
        self.message = message
        self.position = 0
        self.line = 1
        self.column = 1

    fn __init__(
        out self,
        message: String,
        position: Int,
        line: Int,
        column: Int,
    ):
        """Create error with full position information."""
        self.message = message
        self.position = position
        self.line = line
        self.column = column

    fn __copyinit__(out self, other: Self):
        """Copy constructor."""
        self.message = other.message
        self.position = other.position
        self.line = other.line
        self.column = other.column

    fn __moveinit__(out self, deinit other: Self):
        """Move constructor."""
        self.message = other.message^
        self.position = other.position
        self.line = other.line
        self.column = other.column

    fn copy(self) -> Self:
        """Create a copy of this error."""
        return Self(self.message, self.position, self.line, self.column)

    fn __str__(self) -> String:
        """Format error as a human-readable string."""
        return self.format()

    fn format(self) -> String:
        """Format error as a human-readable string."""
        return (
            "JSON parse error at line "
            + String(self.line)
            + ", column "
            + String(self.column)
            + ": "
            + self.message
        )

    fn format_with_context(self, source: String, context_chars: Int = 20) -> String:
        """
        Format error with surrounding context from source.

        Args:
            source: The original JSON source string
            context_chars: Number of characters to show before/after error

        Returns:
            Formatted error message with context
        """
        var start = max(0, self.position - context_chars)
        var end = min(len(source), self.position + context_chars)

        var context = source[start:end]
        var pointer_pos = self.position - start

        # Build pointer line
        var pointer = String("")
        for i in range(pointer_pos):
            pointer += " "
        pointer += "^"

        return (
            self.format()
            + "\n"
            + "Context: ..."
            + context
            + "...\n"
            + "         "
            + pointer
        )


struct JsonErrorCode:
    """Standard JSON error codes."""

    alias UNEXPECTED_CHARACTER: Int = 1
    alias UNEXPECTED_END_OF_INPUT: Int = 2
    alias INVALID_STRING_ESCAPE: Int = 3
    alias INVALID_UNICODE_ESCAPE: Int = 4
    alias INVALID_NUMBER: Int = 5
    alias INVALID_LITERAL: Int = 6
    alias UNTERMINATED_STRING: Int = 7
    alias UNTERMINATED_ARRAY: Int = 8
    alias UNTERMINATED_OBJECT: Int = 9
    alias EXPECTED_COLON: Int = 10
    alias EXPECTED_VALUE: Int = 11
    alias DUPLICATE_KEY: Int = 12
    alias TRAILING_COMMA: Int = 13
    alias NESTING_TOO_DEEP: Int = 14


struct ParseResult[T: Copyable & Movable](Copyable, Movable):
    """
    Result type for parsing operations.

    Either contains a successfully parsed value or an error.
    Use is_ok() to check before accessing value or error.
    """

    var _value: T
    var _error: JsonParseError
    var _is_ok: Bool

    fn __init__(out self, value: T):
        """Create successful result with value."""
        self._value = value.copy()
        self._error = JsonParseError("")
        self._is_ok = True

    fn __init__(out self, error: JsonParseError, value: T):
        """Create error result with a placeholder value."""
        self._value = value.copy()
        self._error = error.copy()
        self._is_ok = False

    fn __copyinit__(out self, other: Self):
        """Copy constructor."""
        self._value = other._value.copy()
        self._error = other._error.copy()
        self._is_ok = other._is_ok

    fn __moveinit__(out self, deinit other: Self):
        """Move constructor."""
        self._value = other._value^
        self._error = other._error^
        self._is_ok = other._is_ok

    @staticmethod
    fn ok(value: T) -> Self:
        """Create successful result."""
        return Self(value)

    @staticmethod
    fn err(error: JsonParseError, default_value: T) -> Self:
        """Create error result."""
        return Self(error, default_value)

    fn is_ok(self) -> Bool:
        """Check if result is successful."""
        return self._is_ok

    fn is_err(self) -> Bool:
        """Check if result is an error."""
        return not self._is_ok

    fn value(self) -> T:
        """
        Get the successful value.

        Precondition: is_ok() must be True.
        """
        return self._value.copy()

    fn error(self) -> JsonParseError:
        """
        Get the error.

        Precondition: is_err() must be True.
        """
        return self._error.copy()

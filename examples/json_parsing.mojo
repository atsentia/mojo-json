"""JSON parsing and serialization examples."""
from mojo_json import parse, stringify, JsonValue, JsonObject

fn main() raises:
    # Parse JSON string
    var json_str = '{"name": "Alice", "age": 30, "active": true}'
    var value = parse(json_str)
    
    print("Name:", value.get("name").as_string())
    print("Age:", value.get("age").as_int())
    print("Active:", value.get("active").as_bool())
    
    # Build JSON object
    var obj = JsonObject()
    obj.set("greeting", JsonValue.from_string("Hello, Mojo!"))
    obj.set("count", JsonValue.from_int(42))
    obj.set("pi", JsonValue.from_float(3.14159))
    
    # Serialize to string
    var output = stringify(obj)
    print("JSON:", output)
    
    # Parse arrays
    var arr_str = '[1, 2, 3, 4, 5]'
    var arr = parse(arr_str)
    print("Array length:", arr.length())

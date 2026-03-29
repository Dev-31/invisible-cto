def calculate_total(a, b):
    # Intentional NameError: c is not defined
    return a + b

if __name__ == "__main__":
    print("Starting test app...")
    result = calculate_total(5, 10)
    print(f"Result is {result}")

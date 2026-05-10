package src.main.java.com.example.fullstackapp.repository;

import org.springframework.data.jpa.repository.JpaRepository;
import src.main.java.com.example.fullstackapp.model.Todo;


public interface TodoRepository extends JpaRepository<Todo, Long> {
}
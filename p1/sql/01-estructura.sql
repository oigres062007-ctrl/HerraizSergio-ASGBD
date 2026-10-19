-- Propietarios de los datos: nadie se conecta con ellos (NOLOGIN)
CREATE ROLE erp_owner NOLOGIN;
CREATE ROLE emp_owner NOLOGIN;

-- Tablespaces en volúmenes distintos
CREATE TABLESPACE tbs_erp       OWNER erp_owner LOCATION '/tablespaces/erp';
CREATE TABLESPACE tbs_empleados OWNER emp_owner LOCATION '/tablespaces/empleados';

CREATE DATABASE empresa;
REVOKE ALL ON DATABASE empresa FROM PUBLIC;

\connect empresa
REVOKE ALL ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA erp       AUTHORIZATION erp_owner;
CREATE SCHEMA empleados AUTHORIZATION emp_owner;

-- Tablas e índices del ERP, en su tablespace
SET default_tablespace = tbs_erp;
SET ROLE erp_owner;
CREATE TABLE erp.clientes (id serial PRIMARY KEY, nombre text NOT NULL);
CREATE TABLE erp.pedidos  (id serial PRIMARY KEY,
                           cliente_id int REFERENCES erp.clientes(id),
                           importe numeric(10,2));
INSERT INTO erp.clientes(nombre) VALUES ('ACME'), ('Globex');
INSERT INTO erp.pedidos(cliente_id, importe) VALUES (1, 100.50), (2, 250.00);
RESET ROLE;

-- Tablas e índices de empleados, en el suyo
SET default_tablespace = tbs_empleados;
SET ROLE emp_owner;
CREATE TABLE empleados.empleados (id serial PRIMARY KEY, nombre text NOT NULL,
                                  departamento text, salario numeric(10,2));
INSERT INTO empleados.empleados(nombre, departamento, salario)
VALUES ('Ana','RRHH',2500), ('Luis','IT',3100), ('Marta','Ventas',2800);
RESET ROLE;
